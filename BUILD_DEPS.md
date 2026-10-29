# MuseScore OH — 编译依赖全景图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ ① App 层(hvigor 构建,build-profile.json5 → externalNativeOptions)        │
│                                                                             │
│   entry (ArkTS/ArkUI)                                                       │
│   ├── pages/Index.ets ──┐                                                   │
│   ├── engine/EngineReader.ets ──┤  oh-package.json5 声明两个 .so 依赖       │
│   └── model/MsczMetadata.ets ──┘                                             │
│         │                          │                                        │
│         ▼                          ▼                                        │
│   ┌─────────────────┐    ┌──────────────────────┐                          │
│   │  libmsohengine.so    │                                              │
│   │  (过渡层)       │    │  (MS4 引擎入口)       │                          │
│   │  zip_reader     │    │  mscore_engine.cpp    │                          │
│   │  mscz_meta      │    │  + qrc_engraving.cpp  │                         │
│   │  (pugixml 内嵌) │    │  + 14 个 qrc_fonts.cpp│                          │
│   └────────┬────────┘    │  + 字体落地到缓存    │                           │
│            │             └──────┬───────────────┘                          │
│            │                    │                                          │
└────────────┼────────────────────┼──────────────────────────────────────────┘
             │                    │ link
             │                    ▼
┌────────────┼────────────────────────────────────────────────────────────────┐
│ ② Native 静态库层(build-engraving/,CMake+Ninja,双 ABI 独立构建)          │
│             │                    │                                          │
│             │             ┌──────▼───────────────────────────────────┐      │
│             │             │       libengraving_cross.a (~590 cpp)   │      │
│             │             │                                          │      │
│             │             │  ┌─ MuseScore 源码 ─────────────────┐    │      │
│             │             │  │ engraving: rw(dom/compat/read*)  │    │      │
│             │             │  │             rendering(paint)     │    │      │
│             │             │  │             dom(editing)         │    │      │
│             │             │  │ ── muse/ 子模块(submodule) ──    │    │      │
│             │             │  │ framework: global/draw/mpe       │    │      │
│             │             │  └──────────────────────────────────┘    │      │
│             │             │  ┌─ .deps/msoh-deps/ ─────────────┐    │      │
│             │             │  │ harfbuzz 12.3   freetype 2.14    │    │      │
│             │             │  │ msdfgen 1.12    pugixml 1.15     │    │      │
│             │             │  │ picojson  utfcpp  lodepng        │    │      │
│             │             │  └──────────────────────────────────┘    │      │
│             │             └──────────────────┬───────────────────┘      │
│             │                                │                          │
│             │         ┌──────────────────────┼──────────────┐           │
│             │         │                      │              │           │
└─────────────┼─────────┼──────────────────────┼──────────────┼───────────┘
              │         │                      │              │
              ▼         ▼                      ▼              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ ③ Qt 6.12 层(按 OHOS_ARCH 条件选择,app CMakeLists.txt 内 if 分支)    │
│                                                                         │
│   ┌────────────────────────┐      ┌────────────────────────┐            │
│   │ arm64-v8a               │      │ x86_64                  │           │
│   │ qt-ohos-kit(官方套件)  │      │ qt-x64-kit(源码自编)   │            │
│   │                         │      │                         │            │
│   │ Qt6Core/Gui/Widgets/Svg │      │ Qt6Core/Gui/Widgets/Svg │            │
│   │ + OpenGL/Concurrent .so │      │ + OpenGL/Concurrent .so │            │
│   │ + libqminimal.so        │      │ + libqminimal.so ★补丁  │            │
│   │                         │      │   (QFreeTypeFontDatabase)│           │
│   └────────────────────────┘      └────────────────────────┘            │
│                                                                         │
│   ┌──────────────────────────┐                                         │
│   │ qt-host-kit(mingw 宿主) │──QT_HOST_PATH──▶ 提供 moc/rcc/qmake    │
│   └──────────────────────────┘         (交叉编译时跑宿主工具)           │
│                                                                         │
│   ┌─────────────────────────────────────────────────────────┐           │
│   │ har 预编译 .so(随 hap 打包):                           │           │
│   │ entry/libs/{arm64-v8a,x86_64}/                          │           │
│   │   Qt6Core/Gui/Widgets/Svg/OpenGL/Concurrent.so           │           │
│   │   libqminimal.so(平台插件)                              │           │
│   └─────────────────────────────────────────────────────────┘           │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
              │                                    │
              │ cross-compile                      │ cross-compile
              ▼                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ ④ SDK 层                                                                │
│                                                                         │
│   OHOS NDK                                                               │
│   ├── ohos.toolchain.cmake ──▶ 所有 native 编译共用此工具链             │
│   ├── llvm/clang(x86_64 + aarch64 双目标)                            │
│   ├── sysroot(含 libz.so / libace_napi.z.so / libEGL.so)             │
│   └── build-tools/cmake+ninja(不用 PATH 里的 msys ninja)               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘


═══════════════════════════════════════════════════════════════════════════
 关键路径(两个 .so 的完整依赖链):

 libmsohengine.so
   ├──▶ libengraving_cross.a
   │      ├──▶ .deps/MuseScore/src/engraving(编译进 .a)
   │      ├──▶ .deps/MuseScore/muse/framework(编译进 .a)
   │      └──▶ .deps/msoh-deps/(8 个三方库,编译进 .a)
   ├──▶ Qt6 Core+CorePrivate+Gui+Widgets+Svg(动态链接 .so)
   ├──▶ freetype(静态链接,libengraving_cross.a 内)
   └──▶ OHOS NDK(libace_napi.z.so + libhilog_ndk.z.so)

 资源(编译进 libmsohengine.so):
   qrc_engraving.cpp      ← rcc engraving.qrc(样式/乐器表)
   qrc_fonts_tabulature   ← rcc fonts_tabulature.qrc
   qrc_fonts_×13          ← rcc data/fonts/*.qrc(音乐字体 68MB 源)
   运行时落地:qrc ":/fonts/*" → cacheDir/fonts/(真实文件路径供
              QFontDatabase::addApplicationFont 使用)
   运行时 CJK:/system/fonts/NotoSansCJK-Regular.ttc → cacheDir + 注册
═══════════════════════════════════════════════════════════════════════════
```

## 目录对应表(全部由 `devecocli build` 自动生成,gitignored)

| 图中节点 | 磁盘路径(均在仓库内,可用 `MSOH_DEPS_ROOT` 外移) |
|---|---|
| entry | `musescore-oh/entry/` |
| libmsohengine 源码 | `entry/src/main/cpp/` |
| libengraving_cross.a | `build-engraving/arm64-v8a/` 与 `build-engraving/x86_64/` |
| engraving-cross CMake | `entry/src/main/cpp/engraving/CMakeLists.txt`(`-DOHOS_ARCH` 切换) |
| MuseScore 源码 | `.deps/MuseScore/src/engraving` + `.deps/MuseScore/muse/`(framework) |
| 三方库 | `.deps/msoh-deps/`(freetype/harfbuzz/msdfgen/pugixml/picojson/utfcpp/lodepng/node-addon-api) |
| Qt arm64 套件 | `.deps/qt-ohos-kit/`(官方 harmonyos_arm64_v8a 组件 + qtdeclarative + qtsvg) |
| Qt x86_64 套件 | `.deps/qt-x64-kit/build-x64/`(自动源码自编 qtbase + qtsvg) |
| Qt 宿主套件 | `.deps/qt-host-kit/`(mingw 构建,供 moc/rcc/qmake;bin/ 内含 mingw 运行时 DLL) |
| hap 预编译 .so | `entry/libs/{arm64-v8a,x86_64}/`(hvigor 打包认这个目录,src/main/libs 不进 hap) |
| rcc 生成的资源 cpp | `entry/src/main/cpp/generated/qrc_*.cpp`(15 个文件) |
