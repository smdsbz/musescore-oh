#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <iomanip>
#include <sstream>
#include <string>

#include "napi/native_api.h"
#include <hilog/log.h>
#include <stdexcept>
#include <algorithm>

#include <QCoreApplication>
#include <QDir>
#include <QImage>
#include <QBuffer>
#include <QPainter>
#include <QFontDatabase>
#include <QRawFont>
#include <QGuiApplication>
#include <map>
#include <mutex>
#include <vector>
#include <dlfcn.h>
#include <QFile>
#include <QFileInfo>

#include <QtCore/private/qcore_ohos_p.h>
#include <QtCore/private/qnapi_p.h>
#include <QtCore/private/qohoscommon_p.h>

#include "draw/internal/qimagepainterprovider.h"
#include "draw/painter.h"
#include "engraving/compat/mscxcompat.h"
#include "engraving/compat/scoreaccess.h"
#include "engraving/dom/instrtemplate.h"
#include "engraving/dom/masterscore.h"
#include "engraving/dom/excerpt.h"
#include "engraving/rendering/score/paint.h"
#include "engraving/dom/mscore.h"
#include "engraving/dom/box.h"
#include "engraving/dom/text.h"
#include "engraving/dom/measurebase.h"
#include "engraving/dom/system.h"
#include "engraving/dom/page.h"
#include "engraving/dom/sig.h"
#include "engraving/dom/staff.h"
#include "engraving/engravingmodule.h"
#include "engraving/infrastructure/smufl.h"
#include "engraving/dom/stafftype.h"
#include "engraving/internal/engravingconfiguration.h"
#include "engraving/style/defaultstyle.h"
#include "draw/internal/ifontsdatabase.h"
#include "draw/types/fontstypes.h"
#include "engraving/internal/engravingfontsprovider.h"
#include "engraving/types/fraction.h"
#include "draw/drawmodule.h"
#include "global/globalmodule.h"
#include "global/tests/mocks/applicationstub.h"


namespace {

const char* KEY_NAMES[15] = {
    "Cb", "Gb", "Db", "Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E", "B", "F#", "C#"
};

std::string ToStd(const muse::String& s)
{
    return s.toStdString();
}

std::string JsonEscape(const std::string& s)
{
    std::ostringstream o;
    for (unsigned char c : s) {
        switch (c) {
            case '"': o << "\\\""; break;
            case '\\': o << "\\\\"; break;
            case '\n': o << "\\n"; break;
            case '\r': o << "\\r"; break;
            case '\t': o << "\\t"; break;
            default:
                if (c < 0x20) {
                    char b[8];
                    snprintf(b, sizeof(b), "\\u%04x", c);
                    o << b;
                } else {
                    o << static_cast<char>(c);
                }
        }
    }
    return o.str();
}

std::string MetaTag(const mu::engraving::MasterScore* score, const char* key)
{
    const auto& tags = score->metaTags();
    auto it = tags.find(muse::String::fromUtf8(key));
    return it == tags.end() ? std::string() : ToStd(it->second);
}

std::string FormatMscVersion(int v)
{
    // 460 -> "4.60", 301 -> "3.01", 206 -> "2.06"
    std::ostringstream o;
    o << (v / 100) << '.' << std::setw(2) << std::setfill('0') << (v % 100);
    return o.str();
}

} // namespace

// --- Headless Qt-OHOS JS-thread bridge ------------------------------------
// Qt-OHOS core routes some init calls (e.g. reading bundle version) through
// QOhosJsThreadGateway, whose backend is normally registered by the ohos
// platform plugin during a Qt app bootstrap. We run headless inside a plain
// napi module, so provide a minimal backend: run tasks inline (calls arrive
// on the JS thread during setup) and let eval()-style lookups throw — Qt's
// call sites catch Napi::Error and degrade gracefully.
static napi_env g_engineNapiEnv = nullptr;
static std::string g_engineCacheDir;

// QFontDatabase::addApplicationFont cannot read qrc ":/..." paths; extract
// font resources to real files once and register those paths instead.
static std::string StageFontResource(const char* rcPath)
{
    static std::map<std::string, std::string> staged;
    auto it = staged.find(rcPath);
    if (it != staged.end()) {
        return it->second;
    }
    std::string out;
    if (!g_engineCacheDir.empty()) {
        // keep the "fonts/<sub>/<file>" layout: EngravingFontsProvider derives
        // metadata.json path from the font file's directory
        std::string rel = rcPath;
        const std::string pfx = ":/";
        if (rel.rfind(pfx, 0) == 0) {
            rel = rel.substr(pfx.size());
        }
        const std::string dir = g_engineCacheDir + "/" + rel.substr(0, rel.rfind('/'));
        QDir().mkpath(QString::fromStdString(dir));
        out = g_engineCacheDir + "/" + rel;
        QFile rc(QString::fromUtf8(rcPath));
        QFile real(QString::fromStdString(out));
        if (rc.open(QIODevice::ReadOnly) && real.open(QIODevice::WriteOnly)) {
            real.write(rc.readAll());
        } else {
            out.clear();
        }
    }
    staged[rcPath] = out;
    return out;
}
static std::mutex g_jsOpsMutex;

class HeadlessJsState final : public QOhosJsState
{
public:
    napi_env env() override { return g_engineNapiEnv; }

    void setModules(napi_env env, napi_value modules)
    {
        napi_create_reference(env, modules, 1, &m_modulesRef);
    }

    std::optional<QNapi::Object> tryGetModule(const std::string& name)
    {
        if (!m_modulesRef || !g_engineNapiEnv) {
            return std::nullopt;
        }
        napi_value map{};
        napi_get_reference_value(g_engineNapiEnv, m_modulesRef, &map);
        if (!map) {
            return std::nullopt;
        }
        napi_value mod{};
        napi_value key{};
        napi_create_string_utf8(g_engineNapiEnv, name.c_str(), name.size(), &key);
        if (napi_get_property(g_engineNapiEnv, map, key, &mod) != napi_ok || !mod) {
            return std::nullopt;
        }
        bool has = false;
        napi_has_property(g_engineNapiEnv, map, key, &has);
        if (!has) {
            return std::nullopt;
        }
        return QNapi::Object(g_engineNapiEnv, mod);
    }
    QNapi::Object defaultWindowStageOrEmpty() override { return QNapi::Object(); }
    QNapi::Object defaultUiContextOrEmpty() override { return QNapi::Object(); }
    std::optional<QNapi::Object> tryGetJsWindowByQWindow(QtOhos::QObjectThreadSafeRef) override { return std::nullopt; }
    std::optional<QNapi::Object> tryGetQAbilityByQWindow(QtOhos::QObjectThreadSafeRef) override { return std::nullopt; }
    std::optional<QNapi::Object> defaultQAbility() override { return std::nullopt; }
    QNapi::Object appLaunchWant() override { return QNapi::Object(); }
    std::optional<QNapi::Object> optAppLaunchParam() override { return std::nullopt; }
    void startAppProcess(const std::string&, QNapi::Object, QNapi::Object,
                         std::function<void(QOhosJsState&)>) override {}
    void startNoUiChildProcess(const std::string&, const std::vector<std::string>&) override {}
    void addNewWantConsumer(QOhosConsumer<QOhosJsState&, QNapi::Object, QNapi::Object>) override {}
    void setOnContinueRequestsHandler(QNapi::Object,
                                      std::function<void(QOhosJsState&, QNapi::Object, QOhosConsumer<QOhosJsState&, QNapi::Number>)>) override {}
    void setDestroyFromSystemAllowed(QNapi::Object, bool) override {}

protected:
    std::tuple<QNapi::Object, std::string> extractModuleFromEvalExpr(const std::string& expr) override
    {
        // expr looks like "@ohos.bundle.bundleManager.BundleFlag.X";
        // try the longest dotted module name the ArkTS side handed us.
        const std::string prefix = "@ohos.";
        std::string path = expr.rfind(prefix, 0) == 0 ? expr.substr(prefix.size()) : expr;
        std::vector<size_t> dots;
        for (size_t i = 0; i < path.size(); ++i) {
            if (path[i] == '.') {
                dots.push_back(i);
            }
        }
        for (int k = static_cast<int>(dots.size()) - 1; k >= 0; --k) {
            auto mod = tryGetModule(path.substr(0, dots[k]));
            if (mod) {
                return { *mod, path.substr(dots[k] + 1) };
            }
        }
        auto whole = tryGetModule(path);
        if (whole) {
            return { *whole, std::string() };
        }
        OH_LOG_Print(LOG_APP, LOG_WARN, 0x0DE0, "MSOHENV", "no JS module for expr: %{public}s", expr.c_str());
        throw Napi::Error::New(g_engineNapiEnv, "headless bridge: no JS module for expr");
    }
    QNapi::Number mapOhosEnumToJs(int, const std::type_info&, OhosEnumInfo(*)()) override
    {
        throw Napi::Error::New(g_engineNapiEnv, "headless bridge: no enums");
    }
    std::optional<int> tryMapOhosEnumFromJs(QNapi::Number, const std::type_info&, OhosEnumInfo(*)()) override
    {
        return std::nullopt;
    }
    int mapOhosEnumFromJs(QNapi::Number, const std::type_info&, OhosEnumInfo(*)()) override
    {
        throw Napi::Error::New(g_engineNapiEnv, "headless bridge: no enums");
    }

    napi_ref m_modulesRef = nullptr;
};

class HeadlessThreadOps final : public QOhosJsThreadOps
{
public:
    QOhosJsState& jsState() override { return m_state; }
    HeadlessJsState& state() { return m_state; }
    void invoke(std::function<void(QOhosJsState&)> task) override
    {
        std::lock_guard<std::mutex> lock(g_jsOpsMutex);
        task(m_state);
    }
    void invokeAndWaitForContinue(std::function<void(QOhosJsState&, QOhosTaskPromise<>)>&& task,
                                  std::string) override
    {
        QOhosTaskPromise<> done([] {}, [] {});
        std::lock_guard<std::mutex> lock(g_jsOpsMutex);
        task(m_state, std::move(done));
    }
    void runAndWait(const std::function<void(QOhosJsState&)>& task, std::string) override
    {
        std::lock_guard<std::mutex> lock(g_jsOpsMutex);
        task(m_state);
    }

private:
    HeadlessJsState m_state;
};

// Mirrors muse::testing::Environment::setup() with the engraving test suite's
// module set (global + draw + engraving), the minimal IOC wiring the engine
// needs to run headless.
static void EnsureEngineEnv()
{
    static bool inited = false;
    if (inited) {
        return;
    }
    inited = true;

    using namespace muse::modularity;
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0DE0, "MSOHENV", "setup begin");
    // ApplicationEventController installs an event filter on qApp; a headless
    // QCoreApplication must exist before any module registration.
    static int argc = 3;
    static char argv0[] = "msohengine";
    static char argv1[] = "-platform";
    static char argv2[] = "minimal:enable_fonts";
    static char* argv[] = { argv0, argv1, argv2, nullptr };
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0DE0, "MSOHENV", "phase: qt-app");
    {
        Dl_info info{};
        if (dladdr(reinterpret_cast<void*>(&EnsureEngineEnv), &info) && info.dli_fname) {
            std::string dir(info.dli_fname);
            auto slash = dir.rfind('/');
            if (slash != std::string::npos) {
                dir.resize(slash);
                setenv("QT_QPA_PLATFORM_PLUGIN_PATH", dir.c_str(), 0);
            }
        }
    }
    static QGuiApplication qtApp(argc, argv);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0DE0, "MSOHENV", "phase: ioc-app");
    static const std::string mname = "msoh";
    globalIoc()->registerExport<muse::IApplication>(mname, new muse::ApplicationStub());

    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0DE0, "MSOHENV", "phase: modules-ctor");
    static muse::GlobalModule globalModule;
    static muse::draw::DrawModule drawModule;
    static mu::engraving::EngravingModule engravingModule;

    globalModule.registerResources();
    globalModule.registerExports();
    globalModule.registerUiTypes();
    drawModule.registerResources();
    drawModule.registerExports();
    engravingModule.registerResources();
    engravingModule.registerExports();

    // ENGRAVING_NO_INTERNAL keeps notation-layer classes out of the module;
    // register the headless internals the engine actually needs by hand
    // (same objects EngravingModule::registerExports would create).
    globalIoc()->registerExport<mu::engraving::IEngravingConfiguration>(
        engravingModule.moduleName(), std::make_shared<mu::engraving::EngravingConfiguration>());
    globalIoc()->registerExport<mu::engraving::IEngravingFontsProvider>(
        engravingModule.moduleName(), std::make_shared<mu::engraving::EngravingFontsProvider>());
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0DE0, "MSOHENV", "registered fonts provider under %{public}s", engravingModule.moduleName().c_str());
    auto check = globalIoc()->resolve<mu::engraving::IEngravingFontsProvider>("x");
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0DE0, "MSOHENV", "resolve check: %{public}p", (void*)check.get());

    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0DE0, "MSOHENV", "phase: manual-reg");
    globalModule.resolveImports();
    // The onInit font table (ENGRAVING_NO_INTERNAL-gated): real fonts now
    // linked via generated qrc_fonts_*.cpp resources.
    {
        auto fdb = globalIoc()->resolve<muse::draw::IFontsDatabase>("engraving");
        auto efonts = std::static_pointer_cast<mu::engraving::EngravingFontsProvider>(
            globalIoc()->resolve<mu::engraving::IEngravingFontsProvider>("engraving"));
        auto addMusicFont = [&](const char* name, const char16_t* family, const std::string& path,
                                const std::string& metadataRc) {
            fdb->addFont(muse::draw::FontDataKey(muse::String(family)), path);
            StageFontResource(metadataRc.c_str());
            efonts->addInternalFont(name, muse::String(family).toStdString(), path);
        };
        fdb->addFont(muse::draw::FontDataKey(u"Edwin", false, false), StageFontResource(":/fonts/edwin/Edwin-Roman.otf"));
        fdb->addFont(muse::draw::FontDataKey(u"Edwin", false, true), StageFontResource(":/fonts/edwin/Edwin-Italic.otf"));
        fdb->addFont(muse::draw::FontDataKey(u"Edwin", true, false), StageFontResource(":/fonts/edwin/Edwin-Bold.otf"));
        fdb->addFont(muse::draw::FontDataKey(u"Edwin", true, true), StageFontResource(":/fonts/edwin/Edwin-BdIta.otf"));
        addMusicFont("Bravura", u"Bravura", StageFontResource(":/fonts/bravura/Bravura.otf"), ":/fonts/bravura/metadata.json");
        fdb->addFont(muse::draw::FontDataKey(u"Bravura Text"), StageFontResource(":/fonts/bravura/BravuraText.otf"));
        addMusicFont("Leland", u"Leland", StageFontResource(":/fonts/leland/Leland.otf"), ":/fonts/leland/metadata.json");
        fdb->addFont(muse::draw::FontDataKey(u"Leland Text"), StageFontResource(":/fonts/leland/LelandText.otf"));
        addMusicFont("Emmentaler", u"MScore", StageFontResource(":/fonts/mscore/MScore.otf"), ":/fonts/mscore/metadata.json");
        fdb->addFont(muse::draw::FontDataKey(u"MScore Text"), StageFontResource(":/fonts/mscore/MScoreText.otf"));
        addMusicFont("Gonville", u"Gootville", StageFontResource(":/fonts/gootville/Gootville.otf"), ":/fonts/gootville/metadata.json");
        fdb->addFont(muse::draw::FontDataKey(u"Gootville Text"), StageFontResource(":/fonts/gootville/GootvilleText.otf"));
        addMusicFont("MuseJazz", u"MuseJazz", StageFontResource(":/fonts/musejazz/MuseJazz.otf"), ":/fonts/musejazz/metadata.json");
        fdb->addFont(muse::draw::FontDataKey(u"MuseJazz Text"), StageFontResource(":/fonts/musejazz/MuseJazzText.otf"));
        addMusicFont("Petaluma", u"Petaluma", StageFontResource(":/fonts/petaluma/Petaluma.otf"), ":/fonts/petaluma/metadata.json");
        fdb->addFont(muse::draw::FontDataKey(u"Petaluma Text"), StageFontResource(":/fonts/petaluma/PetalumaText.otf"));
        addMusicFont("Finale Maestro", u"Finale Maestro", StageFontResource(":/fonts/finalemaestro/FinaleMaestro.otf"), ":/fonts/finalemaestro/metadata.json");
        fdb->addFont(muse::draw::FontDataKey(u"Finale Maestro Text"), StageFontResource(":/fonts/finalemaestro/FinaleMaestroText.otf"));
        addMusicFont("Finale Broadway", u"Finale Broadway", StageFontResource(":/fonts/finalebroadway/FinaleBroadway.otf"), ":/fonts/finalebroadway/metadata.json");
        fdb->addFont(muse::draw::FontDataKey(u"Finale Broadway Text"), StageFontResource(":/fonts/finalebroadway/FinaleBroadwayText.otf"));
        fdb->addFont(muse::draw::FontDataKey(u"FreeSerif"), StageFontResource(":/fonts/FreeSerif.ttf"));
        fdb->addFont(muse::draw::FontDataKey(u"FreeSerif", true, false), StageFontResource(":/fonts/FreeSerifBold.ttf"));
        fdb->addFont(muse::draw::FontDataKey(u"FreeSerif", false, true), StageFontResource(":/fonts/FreeSerifItalic.ttf"));
        fdb->addFont(muse::draw::FontDataKey(u"FreeSerif", true, true), StageFontResource(":/fonts/FreeSerifBoldItalic.ttf"));
        fdb->addFont(muse::draw::FontDataKey(u"FreeSans"), StageFontResource(":/fonts/FreeSans.ttf"));
        fdb->addFont(muse::draw::FontDataKey(u"MScoreTabulature"), StageFontResource(":/fonts/mscoreTab.ttf"));
        fdb->addFont(muse::draw::FontDataKey(u"MscoreBC"), StageFontResource(":/fonts/mscore-BC.ttf"));
        fdb->addFont(muse::draw::FontDataKey(u"Campania"), StageFontResource(":/fonts/campania/Campania.otf"));
        // FontsDatabase::addFont only registers into Qt when built with
        // MUSE_MODULE_DRAW_USE_QTFONTMETRICS; do it explicitly for text faces
        // so QPainter text (title/composer/etc) resolves.
        // CJK: scores embed Japanese/Chinese lyrics; desktop falls back to
        // system CJK fonts. OHOS ships NotoSansCJK as a system font — copy it
        // into our staged fonts dir and register.
        {
            const std::string src = "/system/fonts/NotoSansCJK-Regular.ttc";
            const std::string dst = g_engineCacheDir + "/fonts/NotoSansCJK-Regular.ttc";
            if (QFile::exists(QString::fromStdString(src)) && !QFile::exists(QString::fromStdString(dst))) {
                QFile in(QString::fromStdString(src));
                QFile out(QString::fromStdString(dst));
                if (in.open(QIODevice::ReadOnly) && out.open(QIODevice::WriteOnly)) {
                    out.write(in.readAll());
                }
            }
            if (QFile::exists(QString::fromStdString(dst))) {
                QFontDatabase::addApplicationFont(QString::fromStdString(dst));
            }
        }
        for (const char* rc : { ":/fonts/edwin/Edwin-Roman.otf", ":/fonts/edwin/Edwin-Italic.otf",
             ":/fonts/edwin/Edwin-Bold.otf", ":/fonts/edwin/Edwin-BdIta.otf",
             ":/fonts/FreeSerif.ttf", ":/fonts/FreeSerifBold.ttf", ":/fonts/FreeSerifItalic.ttf",
             ":/fonts/FreeSerifBoldItalic.ttf", ":/fonts/FreeSans.ttf" }) {
            QFontDatabase::addApplicationFont(QString::fromStdString(StageFontResource(rc)));
        }
        // Also gated by ENGRAVING_NO_INTERNAL in EngravingModule::onInit:
        // the SymId -> SMuFL codepoint table (glyphnames.json) and family
        // substitutions. Without it every symbol resolves to a wrong glyph.
        mu::engraving::Smufl::init();
        fdb->setDefaultFont(muse::draw::Font::Type::MusicSymbol, muse::draw::FontDataKey(u"Bravura"));
        fdb->insertSubstitution(u"Leland Text", u"Bravura Text");
        fdb->insertSubstitution(u"Bravura Text", u"Leland Text");
        fdb->insertSubstitution(u"MScore Text", u"Leland Text");
        fdb->insertSubstitution(u"Gootville Text", u"Leland Text");
        fdb->insertSubstitution(u"MuseJazz Text", u"Leland Text");
        fdb->insertSubstitution(u"Petaluma Text", u"MuseJazz Text");
        fdb->insertSubstitution(u"Finale Maestro Text", u"Leland Text");
        fdb->insertSubstitution(u"Finale Broadway Text", u"MuseJazz Text");
        fdb->insertSubstitution(u"ScoreFont", u"Leland Text");

        efonts->setFallbackFont("Bravura");
        efonts->loadAllFonts();
        {
            const auto fams = QFontDatabase::families();
            bool hasLeland = fams.contains("Leland");
            OH_LOG_Print(LOG_APP, LOG_INFO, 0x0DE0, "MSOHENV",
                         "fontdb families=%{public}d leland=%{public}d",
                         fams.size(), (int)hasLeland);
            const std::string lp = StageFontResource(":/fonts/leland/Leland.otf");
            QFile lf(QString::fromStdString(lp));
            OH_LOG_Print(LOG_APP, LOG_INFO, 0x0DE0, "MSOHENV",
                         "staged leland=%{public}s exists=%{public}d size=%{public}lld",
                         lp.c_str(), (int)lf.exists(), lf.exists() ? lf.size() : -1);
            int fid = QFontDatabase::addApplicationFont(QString::fromStdString(lp));
            OH_LOG_Print(LOG_APP, LOG_INFO, 0x0DE0, "MSOHENV",
                         "addApplicationFont id=%{public}d", fid);
            QRawFont rf(QString::fromStdString(lp), 10.0);
            OH_LOG_Print(LOG_APP, LOG_INFO, 0x0DE0, "MSOHENV",
                         "rawfont valid=%{public}d family=%{public}s",
                         (int)rf.isValid(), rf.familyName().toUtf8().constData());
            QFile lf2(QString::fromStdString(lp));
            lf2.open(QIODevice::ReadOnly);
            QRawFont rf2(lf2.readAll(), 10.0);
            OH_LOG_Print(LOG_APP, LOG_INFO, 0x0DE0, "MSOHENV",
                         "rawfont-fromdata valid=%{public}d family=%{public}s",
                         (int)rf2.isValid(), rf2.familyName().toUtf8().constData());
            const std::string tp = StageFontResource(":/fonts/FreeSerif.ttf");
            QRawFont rt(QString::fromStdString(tp), 10.0);
            OH_LOG_Print(LOG_APP, LOG_INFO, 0x0DE0, "MSOHENV",
                         "rawfont-ttf valid=%{public}d family=%{public}s",
                         (int)rt.isValid(), rt.familyName().toUtf8().constData());
        }
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x0DE0, "MSOHENV", "fonts loaded");
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0DE0, "MSOHENV", "phase: preinit");
    drawModule.registerUiTypes();
    drawModule.resolveImports();
    engravingModule.registerUiTypes();
    engravingModule.resolveImports();

    const auto mode = muse::IApplication::RunMode::GuiApp;
    globalModule.onPreInit(mode);
    drawModule.onPreInit(mode);
    engravingModule.onPreInit(mode);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0DE0, "MSOHENV", "phase: oninit");
    globalModule.onInit(mode);
    drawModule.onInit(mode);
    engravingModule.onInit(mode);
    globalModule.onAllInited(mode);
    drawModule.onAllInited(mode);
    engravingModule.onAllInited(mode);

    mu::engraving::MScore::testMode = true;
    mu::engraving::MScore::noGui = true;
    // The remaining ENGRAVING_NO_INTERNAL-gated onInit steps the read chain
    // needs: default style (falls back to :/engraving/styles from our qrc)
    // and the staff-type preset table instruments.xml parsing dereferences.
    // page size is expected in INCHES (styleDef: 210mm / INCH)
    mu::engraving::DefaultStyle::instance()->init({}, {}, mu::engraving::SizeF(210.0 / 25.4, 297.0 / 25.4));
    mu::engraving::StaffType::initStaffTypes(muse::draw::Color::BLACK);
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0DE0, "MSOHENV", "phase: instruments");
    mu::engraving::loadInstrumentTemplates(":/engraving/instruments/instruments.xml");
}

// Must be called on the app main (JS) thread: Qt-OHOS routes core init
// through a JS-thread gateway that does not exist on worker threads.
static napi_value EngineSetup(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    bool ok = false;
    try {
        g_engineNapiEnv = env;
        static HeadlessThreadOps headlessOps;
        QOhosJsThreadOps::registerInstance(&headlessOps);
        if (argc >= 1 && argv[0]) {
            headlessOps.state().setModules(env, argv[0]);
        }
        if (argc >= 2 && argv[1]) {
            size_t clen = 0;
            napi_get_value_string_utf8(env, argv[1], nullptr, 0, &clen);
            g_engineCacheDir.resize(clen);
            napi_get_value_string_utf8(env, argv[1], g_engineCacheDir.data(), clen + 1, &clen);
        }
        EnsureEngineEnv();
        ok = true;
    } catch (const std::exception& e) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0DE0, "MSOHENV", "setup FAILED: %{public}s", e.what());
        ok = false;
    } catch (...) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0x0DE0, "MSOHENV", "setup FAILED by unknown exception");
        ok = false;
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x0DE0, "MSOHENV", "setup end ok=%{public}d", (int)ok);
    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

// Loaded scores stay alive for the whole process: destroying a score
// corrupts loader-shared state, so any later loadMsczOrMscx returns
// FileCriticallyCorrupted (observed with the Aug-2026 main snapshot).
// Handles are append-only; a viewer session opens a handful of scores.
struct OpenedScore {
    mu::engraving::MasterScore* score;
};
static std::mutex g_scoresMutex;
static std::vector<OpenedScore> g_scores;

static mu::engraving::MasterScore* ScoreByHandle(int handle)
{
    std::lock_guard<std::mutex> lock(g_scoresMutex);
    if (handle < 0 || handle >= static_cast<int>(g_scores.size())) {
        return nullptr;
    }
    return g_scores[handle].score;
}

// args: bytes(Uint8Array), tempDir(string)
// Loads the score once, lays out master + all excerpt scores, returns
// metadata with the part list and registers the score under a handle.
static napi_value EngineOpenScore(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_type_error(env, nullptr, "engineOpenScore(bytes: Uint8Array, tempDir: string)");
        return nullptr;
    }

    void* data = nullptr;
    size_t length = 0;
    napi_typedarray_type type;
    napi_get_typedarray_info(env, argv[0], &type, &length, &data, nullptr, nullptr);
    if (type != napi_uint8_array) {
        napi_throw_type_error(env, nullptr, "bytes must be Uint8Array");
        return nullptr;
    }

    size_t dirLen = 0;
    napi_get_value_string_utf8(env, argv[1], nullptr, 0, &dirLen);
    std::string dir(dirLen, '\0');
    napi_get_value_string_utf8(env, argv[1], dir.data(), dirLen + 1, &dirLen);

    const auto t0 = std::chrono::steady_clock::now();
    EnsureEngineEnv();

    static std::atomic<int> seq{ 0 };
    const QString path = QString("%1/mscore_open_%2.mscz")
                             .arg(QString::fromStdString(dir))
                             .arg(seq.fetch_add(1));
    {
        QFile f(path);
        if (!f.open(QIODevice::WriteOnly)) {
            napi_throw_error(env, "E_TMP", "cannot create temp file");
            return nullptr;
        }
        if (length > 0 && f.write(static_cast<const char*>(data), static_cast<qint64>(length))
            != static_cast<qint64>(length)) {
            napi_throw_error(env, "E_TMP", "short write to temp file");
            return nullptr;
        }
    }

    mu::engraving::MasterScore* score
        = mu::engraving::compat::ScoreAccess::createMasterScoreWithBaseStyle(nullptr);
    muse::Ret ret = mu::engraving::compat::loadMsczOrMscx(score, muse::io::path_t(path), false);
    QFile::remove(path);

    std::ostringstream o;
    if (!ret) {
        o << "{\"ok\":false,\"error\":\"" << JsonEscape(ret.toString()) << "\"}";
        delete score;
    } else {
        // 4.6.5 keeps trailing newlines in <text> out of layout; the
        // Aug-2026 main snapshot we build from renders them as an extra
        // empty line. Normalize.
        score->scanElements([](mu::engraving::EngravingItem* e) {
            if (e->isText()) {
                mu::engraving::Text* t = mu::engraving::toText(e);
                muse::String x = t->xmlText();
                while (x.endsWith(muse::Char(u'\n')) || x.endsWith(muse::Char(u'\r'))) {
                    x.remove(x.size() - 1, 1);
                }
                if (x != t->xmlText()) {
                    t->setXmlText(x);
                }
            }
        });
        for (mu::engraving::Score* sc : score->scoreList()) {
            sc->doLayout();
        }

        std::string timeSig;
        const mu::engraving::TimeSigMap* sigmap = score->sigmap();
        if (sigmap && !sigmap->empty()) {
            const mu::engraving::SigEvent& sig = sigmap->begin()->second;
            if (sig.valid()) {
                timeSig = sig.print().toStdString();
            }
        }

        std::string keySig;
        int keyAcc = 0;
        if (score->nstaves() > 0) {
            mu::engraving::Key k = score->staff(0)->key(mu::engraving::Fraction(0, 1));
            keyAcc = static_cast<int>(k);
            int i = keyAcc + 7;
            keySig = (i >= 0 && i <= 14) ? KEY_NAMES[i] : std::to_string(keyAcc);
        }

        std::ostringstream parts;
        for (size_t i = 0; i < score->excerpts().size(); ++i) {
            const mu::engraving::Excerpt* ex = score->excerpts().at(i);
            const mu::engraving::Score* ps = ex->excerptScore();
            if (i > 0) {
                parts << ",";
            }
            parts << "{\"name\":\"" << JsonEscape(ToStd(ex->name())) << "\""
                  << ",\"staves\":" << (ps ? ps->nstaves() : 0)
                  << ",\"measures\":" << (ps ? ps->nmeasures() : 0)
                  << ",\"pages\":" << (ps ? ps->pages().size() : 0)
                  << "}";
        }

        const auto t1 = std::chrono::steady_clock::now();
        double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

        int handle = -1;
        {
            std::lock_guard<std::mutex> lock(g_scoresMutex);
            handle = static_cast<int>(g_scores.size());
            g_scores.push_back({ score });
        }

        o << "{\"ok\":true,\"handle\":" << handle
          << ",\"formatVersion\":\"" << JsonEscape(FormatMscVersion(score->mscVersion())) << "\""
          << ",\"title\":\"" << JsonEscape(MetaTag(score, "workTitle").empty()
                ? MetaTag(score, "title") : MetaTag(score, "workTitle")) << "\""
          << ",\"subtitle\":\"" << JsonEscape(MetaTag(score, "subtitle")) << "\""
          << ",\"composer\":\"" << JsonEscape(MetaTag(score, "composer")) << "\""
          << ",\"lyricist\":\"" << JsonEscape(MetaTag(score, "lyricist")) << "\""
          << ",\"staffCount\":" << score->nstaves()
          << ",\"measureCount\":" << score->nmeasures()
          << ",\"pageCount\":" << score->pages().size()
          << ",\"timeSig\":\"" << JsonEscape(timeSig) << "\""
          << ",\"keySig\":\"" << JsonEscape(keySig) << "\""
          << ",\"keySigAccidentals\":" << keyAcc
          << ",\"parts\":[" << parts.str() << "]"
          << ",\"parseMillis\":" << static_cast<long long>(ms + 0.5)
          << "}";
    }

    napi_value result;
    std::string json = o.str();
    napi_create_string_utf8(env, json.data(), json.size(), &result);
    return result;
}

// args: handle(int), viewIndex(int), outDir(string), dpi(number)
// viewIndex < 0 renders the master score; >= 0 renders excerpts()[i].
// Every page becomes outDir/p<idx>.png (dir created if missing).
static napi_value EngineRenderView(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = { nullptr, nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 3) {
        napi_throw_type_error(env, nullptr, "engineRenderView(handle: number, viewIndex: number, outDir: string, dpi?: number)");
        return nullptr;
    }
    int32_t handle = 0;
    int32_t viewIndex = -1;
    napi_get_value_int32(env, argv[0], &handle);
    napi_get_value_int32(env, argv[1], &viewIndex);
    size_t plen = 0;
    napi_get_value_string_utf8(env, argv[2], nullptr, 0, &plen);
    std::string outDir(plen, '\0');
    napi_get_value_string_utf8(env, argv[2], outDir.data(), plen + 1, &plen);
    double dpi = 150.0;
    if (argc >= 4) {
        napi_get_value_double(env, argv[3], &dpi);
    }
    if (dpi < 36.0) { dpi = 36.0; }
    if (dpi > 300.0) { dpi = 300.0; }

    const auto t0 = std::chrono::steady_clock::now();
    EnsureEngineEnv();

    std::ostringstream o;
    mu::engraving::MasterScore* master = ScoreByHandle(handle);
    mu::engraving::Score* view = nullptr;
    do {
        if (master == nullptr) {
            o << "{\"ok\":false,\"error\":\"invalid handle\"}";
            break;
        }
        if (viewIndex < 0) {
            view = master;
        } else {
            const auto& exs = master->excerpts();
            if (viewIndex >= static_cast<int>(exs.size())) {
                o << "{\"ok\":false,\"error\":\"invalid viewIndex\"}";
                break;
            }
            view = exs.at(viewIndex)->excerptScore();
            if (view == nullptr) {
                o << "{\"ok\":false,\"error\":\"excerpt has no score\"}";
                break;
            }
        }
        if (view->pages().empty()) {
            view->doLayout();
        }
        if (view->pages().empty()) {
            o << "{\"ok\":false,\"error\":\"no pages after layout\"}";
            break;
        }
        QDir().mkpath(QString::fromStdString(outDir));

        const mu::engraving::SizeF psize = mu::engraving::rendering::score::Paint::pageSizeInch(view);
        const int rw = static_cast<int>(psize.width() * dpi);
        const int rh = static_cast<int>(psize.height() * dpi);

        std::ostringstream pages;
        bool ok = true;
        int n = static_cast<int>(view->pages().size());
        for (int i = 0; i < n && ok; ++i) {
            QImage image(rw, rh, QImage::Format_ARGB32_Premultiplied);
            image.setDotsPerMeterX(static_cast<int>((dpi * 1000) / mu::engraving::INCH));
            image.setDotsPerMeterY(static_cast<int>((dpi * 1000) / mu::engraving::INCH));
            image.fill(Qt::white);
            {
                muse::draw::Painter painter(&image, "msoh_render");
                mu::engraving::rendering::IScoreRenderer::ScorePaintOptions opt;
                opt.deviceDpi = static_cast<int>(dpi);
                opt.printPageBackground = false;
                opt.isPrinting = true;
                opt.fromPage = i;
                opt.toPage = i;
                mu::engraving::rendering::score::Paint::paintScore(&painter, view, opt);
            }
            const std::string file = outDir + "/p" + std::to_string(i) + ".png";
            QFile out(QString::fromStdString(file));
            if (!(out.open(QIODevice::WriteOnly) && image.save(&out, "png"))) {
                o << "{\"ok\":false,\"error\":\"write failed at page " << i << "\"";
                ok = false;
                break;
            }
            if (i > 0) {
                pages << ",";
            }
            pages << "{\"file\":\"" << file << "\",\"w\":" << rw << ",\"h\":" << rh << "}";
        }
        if (ok) {
            const auto t1 = std::chrono::steady_clock::now();
            double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
            o << "{\"ok\":true,\"pageCount\":" << n
              << ",\"pages\":[" << pages.str() << "]"
              << ",\"ms\":" << static_cast<long long>(ms + 0.5) << "}";
        }
    } while (false);

    napi_value result;
    std::string json = o.str();
    napi_create_string_utf8(env, json.data(), json.size(), &result);
    return result;
}


static napi_value EngineInfo(napi_env env, napi_callback_info info)
{
    (void)info;
    napi_value result;
    napi_create_string_utf8(env,
                            "msoh native: mscore4 engraving engine (open/render-view, persistent handles) + zip reader",
                            NAPI_AUTO_LENGTH, &result);
    return result;
}


// Font smoke test: draws text + SMuFL glyph with registered families.
static napi_value EngineFontSmoke(napi_env env, napi_callback_info info)
{
    g_engineNapiEnv = env;
    static HeadlessThreadOps headlessOps;
    QOhosJsThreadOps::registerInstance(&headlessOps);
    EnsureEngineEnv();
    size_t argc = 1;
    napi_value argv[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    auto readStr = [&](napi_value v) {
        size_t len = 0;
        napi_get_value_string_utf8(env, v, nullptr, 0, &len);
        std::string s(len, '\0');
        napi_get_value_string_utf8(env, v, s.data(), len + 1, &len);
        return s;
    };
    const std::string outPath = readStr(argv[0]);

    QImage img(900, 400, QImage::Format_ARGB32_Premultiplied);
    img.fill(Qt::white);
    QPainter p(&img);
    p.setPen(Qt::black);
    QFont f1("Edwin", 24);
    p.setFont(f1);
    p.drawText(20, 40, "Edwin: Bad Moon Test 123");
    QFont f2("Leland", 34);
    p.setFont(f2);
    const char16_t smufl[] = u"   ";
    p.drawText(20, 110, QString::fromStdU16String(smufl));
    QFont f3("FreeSerif", 24);
    p.setFont(f3);
    p.drawText(20, 180, "FreeSerif: Bad Moon Test");
    QFont f4("Leland", 24);
    p.setFont(f4);
    p.drawText(20, 250, QString::fromStdU16String(u"NoMerge: "));
    p.setFont(QFont("Bravura", 30));
    p.drawText(20, 320, QString::fromStdU16String(u"Bravura: "));
    p.end();

    // muse::draw::Painter path (what engraving uses)
    QImage img2(900, 260, QImage::Format_ARGB32_Premultiplied);
    img2.fill(Qt::white);
    img2.setDotsPerMeterX(static_cast<int>((120 * 1000) / mu::engraving::INCH));
    img2.setDotsPerMeterY(static_cast<int>((120 * 1000) / mu::engraving::INCH));
    {
        muse::draw::Painter mp(&img2, "smoke2");
        muse::draw::Font f(muse::String::fromUtf8("Leland"), muse::draw::Font::Type::MusicSymbol);
        f.setPointSizeF(10.0);
        mp.setFont(f);
        mp.setPen(muse::draw::Color::BLACK);
        mp.drawSymbol(muse::PointF(20, 60), 0xE050);
        mp.drawSymbol(muse::PointF(80, 60), 0xE0A4);
        mp.drawSymbol(muse::PointF(140, 60), 0xE240);
        muse::draw::Font ft(muse::String::fromUtf8("Edwin"), muse::draw::Font::Type::Text);
        ft.setPointSizeF(12.0);
        mp.setFont(ft);
        mp.drawText(muse::PointF(20, 140), muse::String::fromUtf8("musePainter text: Bad Moon"));
        muse::draw::Font fb(muse::String::fromUtf8("Bravura"), muse::draw::Font::Type::MusicSymbol);
        fb.setPointSizeF(10.0);
        mp.setFont(fb);
        mp.drawSymbol(muse::PointF(20, 220), 0xE050);
        mp.drawSymbol(muse::PointF(90, 220), 0xE0A4);
    }
    QFile out2(QString::fromStdString(outPath + ".2"));
    if (out2.open(QIODevice::WriteOnly)) {
        img2.save(&out2, "png");
    }
    QFile out(QString::fromStdString(outPath));
    bool ok = out.open(QIODevice::WriteOnly) && img.save(&out, "png");
    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

EXTERN_C_START
static napi_value EngineInit(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "engineInfo", nullptr, EngineInfo, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "engineSetup", nullptr, EngineSetup, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "engineOpenScore", nullptr, EngineOpenScore, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "engineRenderView", nullptr, EngineRenderView, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "engineFontSmoke", nullptr, EngineFontSmoke, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module msohEngineModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = EngineInit,
    .nm_modname = "msohengine",
    .nm_priv = ((void *)0),
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterMsohEngineModule(void)
{
    napi_module_register(&msohEngineModule);
}
