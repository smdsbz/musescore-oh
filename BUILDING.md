# MuseScore OH — 编译指南

## 一句话结论

```bash
git clone <repo-url> musescore-oh
cd musescore-oh
devecocli build          # 就这一步,无其他配置
```

首次构建由 `entry/src/main/cpp-engine/CMakeLists.txt` 全自动完成,不需要任何
bash/Python 脚本或手工步骤(纯 CMake):

1. 下载 MuseScore 源码(gitee 镜像)+ muse framework + 8 个三方库 → `.deps/`
2. 下载 Qt 6.12 宿主套件(mingw,提供 rcc/moc)与 HarmonyOS arm64 官方套件
3. 对 muse framework 打 5 处交叉编译补丁(幂等)
4. **x86_64(模拟器)专属**:从源码编译 Qt 6.12 x86_64 套件
   (官方只发 arm64;约 60 分钟,仅首次)
5. 编译 engraving_cross 静态库(双 ABI 各约 15 分钟,仅首次)
6. rcc 生成 qrc 资源、拷贝 Qt .so 到 `entry/libs/<abi>/`
7. hvigor 正常编译 ArkTS + native 并打 hap

## 前置条件

| 工具 | 说明 |
|---|---|
| DevEco Studio ≥ 6.1(含 SDK API 24 / NDK / hvigor) | 提供 `devecocli` |
| Git | 拉取 MuseScore 源码 |
| 7-Zip | 解压 Qt .7z 套件 |

可选环境变量:`MSOH_DEPS_ROOT` 自定义依赖根目录(默认 `<repo>/.deps`)。

## 内置样本(可选)

应用首页的内置样本列表读取 `entry/src/main/resources/rawfile/` 下的 mscz
(bad_moon / stay_with_me / omens_of_love / take_me)。这些是**有版权的乐谱,
不入库**;构建前自行放置(例:从你自己的 MuseScore 导出或测试语料复制):

```bash
cp <你的样本目录>/*.mscz entry/src/main/resources/rawfile/
```

不放也能构建运行:首页样本列表点开无谱可载,「从文件选择 .mscz」功能不受影响。

## 首次构建耗时与体积

| 阶段 | 下载量 | 耗时 |
|---|---|---|
| MuseScore + 三方库 + Qt 套件下载 | ~500MB | 视网速 5-20 分钟 |
| Qt x86_64 自编(仅模拟器 ABI) | — | ~60 分钟 |
| engraving 双 ABI | — | ~15 分钟 × 2 |
| hvigor 常规构建 | — | ~5 分钟 |

`.deps/` 最终约占 8-10GB。**只要真机(arm64)不需要模拟器,可把
`entry/build-profile.json5` 中 `abiFilters` 的 `x86_64` 删掉,即可跳过 Qt 自编。**

## 生成目录(gitignored,可随时删除重建)

```
.deps/                     依赖与套件缓存(MuseScore/ msoh-deps/ qt-*kit/)
build-engraving/<abi>/     engraving_cross 静态库构建目录
entry/libs/<abi>/          随 hap 打包的 Qt .so(含 libqminimal.so)
entry/src/main/cpp-engine/generated/   rcc 产物(qrc_*.cpp)
entry/.cxx/ entry/build/  hvigor 的 cmake/hap 产物
```

## 常见问题

**Q: 构建中断后重来会重复下载/重编吗?**
A: 不会。所有阶段按产物存在性跳过;下载带断点续传(curl -C -,15 次重试);解压走临时目录+原子改名;configure 失败会自动清目录重试一次。

**Q: 构建被强杀(关终端/Ctrl-C)后重跑报 `ninja: failed recompaction: Permission denied`?**
A: 被杀的 hvigor 会遗留孤儿 ninja/clang 进程仍持有构建目录锁。先
`tasklist | findstr ninja` 结束残留进程再重跑。

**Q: 想彻底重来?**
A: 删 `.deps/` 与 `build-engraving/` 再 `devecocli build`。

**Q: rcc/moc 报缺 DLL?**
A: `qt-host-kit/bin/` 下应有 libgcc_s_seh-1.dll 等(mingw 运行时,自动解压到位)。

**Q: 模拟器上启动即闪退?**
A: 确认 hap 里带了 Qt .so(解包 hap 看 `libs/x86_64/`);`entry/libs/<abi>/` 是
hvigor 认的打包目录,`src/main/libs` 不会被打进 hap。

**Q: 链接报 undefined symbol qInitResources_fonts_*?**
A: `generated/` 下的 qrc cpp 缺失,删掉该目录重跑(会重新生成)。

## 许可

本项目为 GPL-3.0(内嵌 MuseScore engraving + Qt LGPL 动态链接 + 各字体/三方库许可),
详见 `LICENSE` 与 `licenses/`。
