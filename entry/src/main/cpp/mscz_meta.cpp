#include "mscz_meta.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <sstream>
#include <cmath>
#include <string>

#include "thirdparty/pugixml/pugixml.hpp"
#include "zip_reader.h"

namespace msoh {

namespace {

const char* KEY_NAMES[15] = {
    "Cb", "Gb", "Db", "Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E", "B", "F#", "C#"
};

std::string Trim(const std::string& s)
{
    size_t b = s.find_first_not_of(" \t\r\n");
    if (b == std::string::npos) {
        return "";
    }
    size_t e = s.find_last_not_of(" \t\r\n");
    return s.substr(b, e - b + 1);
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
                    char buf[8];
                    snprintf(buf, sizeof(buf), "\\u%04x", c);
                    o << buf;
                } else {
                    o << static_cast<char>(c); // UTF-8 passthrough
                }
        }
    }
    return o.str();
}

std::string KeyName(int acc)
{
    int i = acc + 7;
    if (i < 0 || i > 14) {
        return std::to_string(acc);
    }
    return KEY_NAMES[i];
}

// Concatenates all descendant character data of `node` (handles <text>
// wrapping nested markup like <font>/<b> — MuseScore rich-text XML).
std::string CollectText(const pugi::xml_node& node)
{
    std::string out;
    if (!node) {
        return out;
    }
    for (pugi::xml_node n : node.children()) {
        if (n.type() == pugi::node_pcdata || n.type() == pugi::node_cdata) {
            out += n.value();
        } else {
            out += CollectText(n);
        }
    }
    return out;
}

std::string Lower(std::string s)
{
    for (char& c : s) {
        if (c >= 'A' && c <= 'Z') {
            c = static_cast<char>(c - 'A' + 'a');
        }
    }
    return s;
}

struct Meta {
    std::string formatVersion;
    std::string programVersion;
    std::string title;
    std::string subtitle;
    std::string composer;
    std::string lyricist;
    int staffCount = 0;
    int measureCount = 0;
    std::string timeSig;
    std::string keySig;
    int keyAccidentals = 0;
    int tempoBpm = 0;
    int division = 0;
    bool keyFromConcert = false;
};

// VBoxes live INSIDE <Staff> (title frames), and MS3 excerpts add nested
// <Score> blocks with their own VBoxes — collect in document order, first
// match wins so main-score titles take precedence over excerpt copies.
void ReadVBoxTexts(const pugi::xml_node& score, Meta& m)
{
    std::vector<pugi::xml_node> vboxes;
    std::function<void(const pugi::xml_node&)> collect = [&](const pugi::xml_node& n) {
        for (pugi::xml_node c : n.children()) {
            if (std::string(c.name()) == "VBox") {
                vboxes.push_back(c);
            }
            collect(c);
        }
    };
    collect(score);

    for (const pugi::xml_node& vbox : vboxes) {
        for (pugi::xml_node text : vbox.children("Text")) {
            std::string style = Lower(Trim(text.child_value("style")));
            std::string value = Trim(CollectText(text.child("text")));
            if (value.empty()) {
                continue;
            }
            if (style == "title" && m.title.empty()) { m.title = value; }
            else if (style == "subtitle" && m.subtitle.empty()) { m.subtitle = value; }
            else if (style == "composer" && m.composer.empty()) { m.composer = value; }
            else if (style == "lyricist" && m.lyricist.empty()) { m.lyricist = value; }
        }
    }
}

// Depth-first first-occurrence scan for the leading TimeSig / KeySig / Tempo.
void ReadFirstElements(const pugi::xml_node& score, Meta& m)
{
    bool keyDone = false;
    bool timeDone = false;
    bool tempoDone = false;

    std::function<void(const pugi::xml_node&)> walk = [&](const pugi::xml_node& n) {
        const std::string name = n.name();
        if (!timeDone && name == "TimeSig") {
            int sn = std::atoi(n.child_value("sigN"));
            int sd = std::atoi(n.child_value("sigD"));
            if (sn > 0 && sd > 0) {
                m.timeSig = std::to_string(sn) + "/" + std::to_string(sd);
                timeDone = true;
            }
        }
        if (!keyDone && name == "KeySig") {
            pugi::xml_node acc = n.child("accidental");
            pugi::xml_node ck = n.child("concertKey");
            if (acc) {
                m.keyAccidentals = std::atoi(acc.child_value());
                m.keySig = KeyName(m.keyAccidentals);
                keyDone = true;
            } else if (ck) {
                m.keyAccidentals = std::atoi(ck.child_value());
                m.keySig = KeyName(m.keyAccidentals);
                m.keyFromConcert = true;
                keyDone = true;
            }
        }
        if (!tempoDone && name == "Tempo") {
            double t = std::atof(n.child_value("tempo"));
            if (t > 0) {
                m.tempoBpm = static_cast<int>(std::lround(t * 60.0));
                tempoDone = true;
            }
        }
        for (pugi::xml_node c : n.children()) {
            if (timeDone && keyDone && tempoDone) {
                return;
            }
            walk(c);
        }
    };
    walk(score);
}

} // namespace

std::string ExtractMetaJson(const uint8_t* data, size_t size, std::string& error)
{
    error.clear();
    const auto t0 = std::chrono::steady_clock::now();

    std::string entryName;
    std::string mscx = ReadEntryBySuffix(data, size, ".mscx", entryName, error);
    if (!error.empty()) {
        return {};
    }

    pugi::xml_document doc;
    pugi::xml_parse_result r = doc.load_buffer(mscx.data(), mscx.size());
    if (!r) {
        error = std::string("mscx parse error: ") + r.description();
        return {};
    }

    pugi::xml_node root = doc.child("museScore");
    pugi::xml_node score = root ? root.child("Score") : pugi::xml_node();
    if (!score) {
        error = "no <museScore>/<Score>";
        return {};
    }

    Meta m;
    m.formatVersion = root.attribute("version").as_string();
    // <programVersion> sits directly under <museScore>, before <Score>.
    m.programVersion = Trim(root.child_value("programVersion"));

    int verMajor = 0;
    {
        std::string v = m.formatVersion;
        size_t dot = v.find('.');
        verMajor = dot == std::string::npos ? 0 : std::atoi(v.substr(0, dot).c_str());
    }
    const bool legacy = verMajor < 3; // 1.x/2.x: explicit <Measure number="N">

    // Score-level staves are direct <Score> children; <Staff> under <Part>
    // (instrument descriptions, also id-annotated in 2.x/3.x) must be skipped.
    pugi::xml_node firstStaff;
    for (pugi::xml_node n : score.children("Staff")) {
        m.staffCount += 1;
        if (!firstStaff) {
            firstStaff = n;
        }
    }

    if (legacy) {
        int maxNumber = 0;
        std::function<void(const pugi::xml_node&)> collectNumbers =
            [&](const pugi::xml_node& n) {
                for (pugi::xml_node c : n.children()) {
                    if (std::string(c.name()) == "Measure") {
                        int num = c.attribute("number").as_int(0);
                        if (num > maxNumber) {
                            maxNumber = num;
                        }
                    }
                    collectNumbers(c);
                }
            };
        collectNumbers(score);
        m.measureCount = maxNumber;
    } else if (firstStaff) {
        // Measures repeat per staff; the first score staff carries the real count.
        int count = 0;
        for (pugi::xml_node measure : firstStaff.children("Measure")) {
            count += 1;
        }
        m.measureCount = count;
    }

    ReadVBoxTexts(score, m);
    ReadFirstElements(score, m);
    m.division = score.child("Division").text().as_int(0);

    if (m.keyFromConcert) {
        m.keySig += " (concert)";
    }

    const auto t1 = std::chrono::steady_clock::now();
    double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

    std::ostringstream o;
    o << "{"
      << "\"fileName\":\"\","
      << "\"mscxEntry\":\"" << JsonEscape(entryName) << "\","
      << "\"formatVersion\":\"" << JsonEscape(m.formatVersion) << "\","
      << "\"programVersion\":\"" << JsonEscape(m.programVersion) << "\","
      << "\"title\":\"" << JsonEscape(m.title) << "\","
      << "\"subtitle\":\"" << JsonEscape(m.subtitle) << "\","
      << "\"composer\":\"" << JsonEscape(m.composer) << "\","
      << "\"lyricist\":\"" << JsonEscape(m.lyricist) << "\","
      << "\"staffCount\":" << m.staffCount << ","
      << "\"measureCount\":" << m.measureCount << ","
      << "\"timeSig\":\"" << JsonEscape(m.timeSig) << "\","
      << "\"keySig\":\"" << JsonEscape(m.keySig) << "\","
      << "\"keySigAccidentals\":" << m.keyAccidentals << ","
      << "\"tempoBpm\":" << m.tempoBpm << ","
      << "\"division\":" << m.division << ","
      << "\"parseMillis\":" << static_cast<long long>(ms + 0.5)
      << "}";
    return o.str();
}

} // namespace msoh
