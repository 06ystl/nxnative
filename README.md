# nxnative

[中文说明](#中文说明)

Play your own Nintendo Switch games natively on iPhone and iPad. Bring your game (its NSP files) and your `prod.keys`; one script turns them into an IPA that you sideload.

It is not an emulator: the game's own code runs directly on the Apple chip, with Switch graphics rebuilt on Metal. Nothing from any game is in this repository, and the project is not affiliated with Nintendo or any game publisher.

## Acknowledgements

This project is built on other people's work:

- **[d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile)** (MIT) developed this native-execution approach, for Diablo II: Resurrected. nxnative (first called smbw-mobile) started as a copy of its generic parts: the NSO rewriter, the host that stands in for Horizon, the NVN-on-Metal layer and the iOS app shell. Fixes go both ways.
- **Ryujinx** (MIT): its shader translator (`Ryujinx.Graphics.Shader`, `Ryujinx.Common` and `Spv.Generator` 1.3.2, unmodified in `dm/third_party/ryujinx`) turns the games' Maxwell shaders into SPIR-V. Its emulation of the kernel and system services is also a reference when the host's behaviour is in doubt.
- **[Atmosphère](https://github.com/Atmosphere-NX/Atmosphere)**: its kernel, mesosphère, is the reference for Horizon's synchronization semantics (address arbiter, condition variables).
- **yuzu**: Maxwell instruction encodings for the shader reference tool, and a cross-check for kernel behaviour.
- **[LibHac](https://github.com/Thealexbarney/LibHac)**: reads NSPs and layers updates over the base game in `dm/tools/nx_extract`. **hactool** did the first extractions.
- **[SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross)**: SPIR-V to Metal Shading Language.
- **deko3d** (zlib): its texture layout size algorithm is ported in `dm/gfx/nvn/nvn_tex.c`.
- **libvpx** (VP9 movies), **stb_vorbis** (movie sound), **libdeflate**, **bcdec** and **NVIDIA FLIP** ship in `dm/third_party` with their licenses ([list](dm/third_party/README.md)).
- **Capstone**, **lz4**, **fontTools** and **XcodeGen** are used by the build.

## Games

All of these are tested on an iPhone and playable:

| Game | NSPs to put in the folder | IPA | Notes |
|---|---|---|---|
| Super Mario Bros. Wonder | base game + update 1.2.1 | ~4 GB | |
| Fire Emblem Engage | base game + update 2.0.0 (+ Expansion Pass DLC) | ~15 GB | Upgraded to 60 fps (30 fps on Switch) |
| Metroid Dread | base game + update 2.1.0 | ~5 GB | |
| 13 Sentinels: Aegis Rim | base game + update 1.10 | ~5 GB | |
| Super Mario 3D World + Bowser's Fury | base game + update 1.2.2 | ~3 GB | |
| The Legend of Zelda: Breath of the Wild | base game + update 1.9.0 (+ DLC) | ~16 GB | Upgraded to 60 fps (30 fps on Switch) |

New, runs on the Mac, not yet tested on an iPhone: The Legend of Zelda: Link's Awakening (base game + update 1.1.0, ~6 GB).

Needs iOS / iPadOS 26 or later. Other games aren't supported yet: for them the script writes a survey instead of an IPA.

## Pack an IPA

**1. Get nxnative and its tools** (once, on a Mac with [Xcode](https://apps.apple.com/app/xcode/id497799835) and [Homebrew](https://brew.sh)):

```
git clone https://github.com/seedds/nxnative.git && cd nxnative
brew install xcodegen zstd spirv-cross
brew install --cask dotnet-sdk
python3 -m pip install lz4 capstone fonttools
```

**2. Put one game's NSPs in a folder**, base game and update (and any DLC):

```
~/Games/MarioWonder/
  Super Mario Bros. Wonder [010015100B514000][v0].nsp
  Super Mario Bros. Wonder [010015100B514800][v327680].nsp
```

**3. Run the script:**

```
python3 scripts/build_ipa_from_nsp.py ~/Games/MarioWonder -k ~/keys/prod.keys
```

The IPA appears in the same folder (here `~/Games/MarioWonder/SMBWMobile.ipa`). The first build takes 30–60 minutes, later ones about 10. You need free disk space of about twice the NSPs' size plus 10 GB. Options such as `-o` (output path) and `--app-name` are listed by `-h`.

**4. Install** the IPA with your sideloading tool (AltStore, Sideloadly, LiveContainer, …). The app gets the game's name and icon.

## Build Mac and iOS apps together

To produce both packages, run the shared build script on an Apple silicon Mac with macOS 26+ and Xcode 26+:

```
python3 scripts/build_apps_from_nsp.py /Volumes/Games/MarioWonder -k /Volumes/Games/keys/prod.keys --target both
```

This writes `SMBWMobile.app` and `SMBWMobile.ipa` beside the NSPs. Extraction, code rewriting and shader processing run once for both platforms. Use `--target macos` or `--target ios` for just one. `-o /Volumes/Games/Builds` sets the output folder; `--out-app` and `--out-ipa` set individual output paths.

In Spyder, open `scripts/build_apps_from_nsp.py`, fill in `NSP_DIR` and `PROD_KEYS`, leave `TARGET = 'both'`, save and press F5. Extraction is removed only after all selected packages succeed; `--keep-extracted` keeps it for later builds. If one platform fails during packaging, the script still attempts the other and keeps completed packages and extracted files. Retry with `--target macos` or `--target ios` for the failed platform. The existing separate scripts remain available.

## Pack a Mac app

On an Apple silicon Mac with macOS 26+ and Xcode 26+, use the same NSP folder and keys:

```
python3 scripts/build_mac_app_from_nsp.py /Volumes/Games/MarioWonder -k /Volumes/Games/keys/prod.keys
```

This produces `SMBWMobile.app` beside the NSPs. Double-click it to play; the app includes the game files, macOS shaders and icon, with a local ad-hoc signature. No developer account is needed. In Spyder, set `NSP_DIR` and `PROD_KEYS` at the top of the new script and press F5; `OUT_APP` changes the output path. Keep game files and builds on your game drive.

Mac apps use an optimized Release host (`-O2`) by default. The same setting applies to `--target macos` and `--target both` in the unified script.

Mac input: WASD = left stick, arrows = D-pad, J/K/U/I = A/B/X/Y, Q/E = L/R, Z/C = ZL/ZR, Return/Tab = +/−, F/G = stick presses. Click or drag for touchscreen input. ⌘Q quits; ⌃⌘F toggles full screen.

Physical controllers: pair over Bluetooth or plug in over USB, then focus the game window. macOS must recognize an extended gamepad (for example Xbox, PlayStation or Switch Pro). The first supported controller controls player 1; connecting or reconnecting while the app runs is supported. Nintendo and Xbox face buttons follow their printed letters; PlayStation uses × = A, ○ = B, □ = X, △ = Y. Both sticks, D-pad, shoulders, triggers, stick clicks and menu/options buttons are mapped. Keyboard input works alongside the controller. Switching apps, Spaces, full screen or displays clears held input and rebinds the controller when the game regains focus. Rebuild older apps with `--target macos` to include these fixes. The input path and focus recovery have regression coverage using Apple's software controller snapshots; physical Xbox right-stick input and camera-sensitivity changes have also been verified in Breath of the Wild.

Saves are in `~/Library/Application Support/org.nxnative.<title-id>/save`, logs in `~/Library/Logs/org.nxnative.<title-id>/log.txt` (title ID in lowercase). Put `env.txt` next to `save/` for settings. The minimum OS follows the bundled shader libraries: cached libraries from a newer SDK can raise it above macOS 26. Mac compatibility varies by game; Mario's menu and dialogue text currently render blank.

Rebuilt Mac apps apply the validated state and buffer caches automatically; Breath of the Wild also enables uniform-update batching through its profile. These optimizations preserve the game's resolution, effects and timing. Use `DM_LANG=zh-Hans` for Simplified Chinese and `DM_OPMODE=0` for handheld mode if desired; restart after changing settings. See the [environment-variable guide](docs/development.md#mac-environment-variables) for the remaining options.

Breath of the Wild 1.9.0 Mac builds support `DM_GAME_RES=1920x1080` for true 1080p scene rendering, HUD and output, or `DM_GAME_RES=1280x720` for 720p. Put the setting in your `env.txt` and restart. Higher resolution uses more GPU time; select the preset that gives you the clarity and frame rate you prefer.

## Play

**Touch controls.** Tap **2D** / **3D** at the top to switch layouts; the app remembers your choice. 3D World and Breath of the Wild start in 3D, the other games in 2D.

```
 ZL  L3*        [−]  2D/3D  [+]        R3*  ZR
 L                                           R
                                         X
  ( L stick )                          Y   A
             ✚ D-pad*   ( R stick )*     B
                                  * 3D layout only
```

A connected game controller hides the touch controls and keeps every button.

- **Game language** is English by default. For Chinese, add the line `DM_LANG=zh-Hans` to `Documents/env.txt`.
- **Saves and logs** are in the Files app, under the app's name: `save/` and `log.txt`. When something goes wrong, send `log.txt` (the previous run is `log.prev.txt`).
- **Short stutters** the first time a new scene appears are normal: the app compiles graphics for it once and remembers them for the next launch.
- **Reinstalling:** some sideloading tools give a reinstalled app a new data folder. Copy `save/` and `pso_user.tsv` over from the old one to keep your progress.
- **Settings without rebuilding:** put lines like `DM_OPMODE=0` (handheld mode: lower resolution, higher frame rate) in `Documents/env.txt`.

## Known issues

- No amiibo and no online features.
- Fire Emblem Engage: after switching away from the app and back, some sounds may stay silent until you restart it.
- Super Mario 3D World: a few small magenta squares can appear near the birds in World 1-1.

## For developers

How it works, the script's options, running games on the Mac, adding a game, and per-game notes: [docs/development.md](docs/development.md). In-depth bring-up and debugging notes: [docs/agents](docs/agents/README.md).

## License

MIT (see [LICENSE](LICENSE)). Third-party code keeps its own license; see [dm/third_party](dm/third_party/README.md).

---

# 中文说明

在 iPhone 和 iPad 上原生运行你自己的 Nintendo Switch 游戏。准备好游戏（NSP 文件）和你的 `prod.keys`，一个脚本就能把它们打包成 IPA，再侧载安装。

这不是模拟器：游戏自己的代码直接跑在苹果芯片上，Switch 的图形在 Metal 上重建。本仓库不含任何游戏内容，项目与任天堂及各游戏发行商无关。

## 致谢

本项目建立在他人的工作之上：

- **[d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile)**（MIT）为《暗黑破坏神 II：狱火重生》开发了这套原生运行方法。nxnative（最初叫 smbw-mobile）从它的通用部分起步：NSO 改写器、代替 Horizon 的宿主、Metal 上的 NVN 层和 iOS 应用外壳。修正双向共享。
- **Ryujinx**（MIT）：它的着色器翻译器（`Ryujinx.Graphics.Shader`、`Ryujinx.Common` 和 `Spv.Generator` 1.3.2，原样放在 `dm/third_party/ryujinx`）把游戏的 Maxwell 着色器转成 SPIR-V。宿主行为拿不准时，它对内核和系统服务的模拟也是参考。
- **[Atmosphère](https://github.com/Atmosphere-NX/Atmosphere)**：它的内核 mesosphère 是 Horizon 同步语义（地址仲裁器、条件变量）的参考。
- **yuzu**：着色器参考工具用到的 Maxwell 指令编码，以及内核行为的交叉核对。
- **[LibHac](https://github.com/Thealexbarney/LibHac)**：在 `dm/tools/nx_extract` 里读取 NSP、把更新叠到本体上。最早的解包用的是 **hactool**。
- **[SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross)**：SPIR-V 转 Metal 着色语言。
- **deko3d**（zlib）：`dm/gfx/nvn/nvn_tex.c` 移植了它的贴图布局尺寸算法。
- **libvpx**（VP9 影片）、**stb_vorbis**（影片声音）、**libdeflate**、**bcdec** 和 **NVIDIA FLIP** 连同许可证放在 `dm/third_party`（[清单](dm/third_party/README.md)）。
- 构建时用到 **Capstone**、**lz4**、**fontTools** 和 **XcodeGen**。

## 游戏

以下游戏都已在 iPhone 上测试，可以正常游玩：

| 游戏 | 文件夹里放的 NSP | IPA 大小 | 备注 |
|---|---|---|---|
| 超级马力欧兄弟 惊奇 | 本体 + 1.2.1 更新 | 约 4 GB | |
| 火焰纹章 Engage | 本体 + 2.0.0 更新（+ 扩展通行证 DLC） | 约 15 GB | 升级到 60 fps（Switch 上 30 fps） |
| 密特罗德 生存恐惧 | 本体 + 2.1.0 更新 | 约 5 GB | |
| 十三机兵防卫圈 | 本体 + 1.10 更新 | 约 5 GB | |
| 超级马力欧 3D 世界 + 狂怒世界 | 本体 + 1.2.2 更新 | 约 3 GB | |
| 塞尔达传说 旷野之息 | 本体 + 1.9.0 更新（+ DLC） | 约 16 GB | 升级到 60 fps（Switch 上 30 fps） |

新加入、已在 Mac 上运行、还没在 iPhone 上测试：塞尔达传说 织梦岛（本体 + 1.1.0 更新，约 6 GB）。

需要 iOS / iPadOS 26 或更高版本。其他游戏暂不支持：脚本会为它们写一份分析报告，而不是出 IPA。

## 打包 IPA

**1. 获取 nxnative 和所需工具**（只需一次，在装有 [Xcode](https://apps.apple.com/app/xcode/id497799835) 和 [Homebrew](https://brew.sh) 的 Mac 上）：

```
git clone https://github.com/seedds/nxnative.git && cd nxnative
brew install xcodegen zstd spirv-cross
brew install --cask dotnet-sdk
python3 -m pip install lz4 capstone fonttools
```

**2. 把一个游戏的 NSP 放进一个文件夹**，本体和更新（有 DLC 也放进去）：

```
~/Games/MarioWonder/
  Super Mario Bros. Wonder [010015100B514000][v0].nsp
  Super Mario Bros. Wonder [010015100B514800][v327680].nsp
```

**3. 运行脚本：**

```
python3 scripts/build_ipa_from_nsp.py ~/Games/MarioWonder -k ~/keys/prod.keys
```

IPA 会出现在同一个文件夹里（这里是 `~/Games/MarioWonder/SMBWMobile.ipa`）。第一次打包要 30–60 分钟，之后约 10 分钟。需要的空闲磁盘空间约为 NSP 大小的两倍再加 10 GB。`-o`（输出路径）、`--app-name` 等选项用 `-h` 查看。

**4. 安装**：用你的侧载工具（AltStore、Sideloadly、LiveContainer 等）安装 IPA。App 会带上游戏的名字和图标。

## 一次构建 Mac 和 iOS 安装包

需要两种安装包时，在装有 macOS 26+、Xcode 26+ 的 Apple 芯片 Mac 上运行统一构建脚本：

```
python3 scripts/build_apps_from_nsp.py /Volumes/Games/MarioWonder -k /Volumes/Games/keys/prod.keys --target both
```

脚本会在 NSP 旁生成 `SMBWMobile.app` 和 `SMBWMobile.ipa`。解包、代码改写和着色器处理共用一次。只需要一种时，使用 `--target macos` 或 `--target ios`。`-o /Volumes/Games/Builds` 设置输出文件夹；`--out-app` 和 `--out-ipa` 分别指定完整输出路径。

在 Spyder 中打开 `scripts/build_apps_from_nsp.py`，填写 `NSP_DIR`、`PROD_KEYS`，保留 `TARGET = 'both'`，保存后按 F5。只有所选安装包全部成功后才删除解包文件；使用 `--keep-extracted` 可以留待下次构建。某个平台打包失败时，脚本仍会尝试另一个平台，并保留已完成的安装包和解包文件；可以用 `--target macos` 或 `--target ios` 重试失败的平台。原来的两个独立脚本仍可使用。

## 打包 Mac App

在装有 macOS 26+、Xcode 26+ 的 Apple 芯片 Mac 上，使用同样的 NSP 文件夹和密钥：

```
python3 scripts/build_mac_app_from_nsp.py /Volumes/Games/MarioWonder -k /Volumes/Games/keys/prod.keys
```

脚本会在 NSP 旁生成 `SMBWMobile.app`，双击即可启动；包内包含游戏文件、macOS 着色器和图标，并使用本地临时签名，无需开发者账号。在 Spyder 中填写新脚本顶部的 `NSP_DIR`、`PROD_KEYS` 后按 F5；`OUT_APP` 可以更改输出路径。游戏文件和构建产物请放在存放游戏的磁盘上。

Mac App 默认使用优化的 Release 宿主（`-O2`）。统一脚本的 `--target macos` 和 `--target both` 也使用这一设置。

Mac 键位：WASD = 左摇杆，方向键 = 十字键，J/K/U/I = A/B/X/Y，Q/E = L/R，Z/C = ZL/ZR，Return/Tab = +/−，F/G = 按下左右摇杆。鼠标单击或拖动模拟触屏。⌘Q 退出，⌃⌘F 切换全屏。

实体手柄：通过蓝牙配对或 USB 连接后，让游戏窗口处于前台。手柄需被 macOS 识别为完整游戏手柄，例如 Xbox、PlayStation 或 Switch Pro。第一个支持的手柄控制 1P，支持运行中连接和重新连接。任天堂和 Xbox 手柄的面键按键帽字母映射；PlayStation 对应 × = A、○ = B、□ = X、△ = Y。双摇杆、十字键、肩键、扳机、摇杆按下和菜单／选项键均已映射，键盘可以同时使用。切换应用、桌面、全屏或显示器时会清空按住的输入，游戏重新获得焦点后会重新绑定手柄。旧版 App 请用 `--target macos` 重新构建以包含这些修复。输入通路与焦点恢复已用苹果的软件手柄快照做回归测试；实体 Xbox 手柄的右摇杆输入及视角灵敏度修改也已在旷野之息中验证。

存档位于 `~/Library/Application Support/org.nxnative.<标题号>/save`，日志位于 `~/Library/Logs/org.nxnative.<标题号>/log.txt`（标题号小写）。在 `save/` 旁放置 `env.txt` 可以调整设置。最低系统版本取决于包内着色器库：复用较新 SDK 生成的缓存时，可能高于 macOS 26。各游戏的 Mac 兼容性不同；目前马力欧的菜单和对话文字存在空白问题。

重新构建的 Mac App 会自动启用已验证的状态和缓冲区缓存；旷野之息还会通过游戏档案自动启用 uniform 更新批处理。这些优化保留游戏原有的分辨率、特效和运行时序。需要时可设置 `DM_LANG=zh-Hans` 使用简体中文、`DM_OPMODE=0` 使用掌机模式，修改后重启游戏。其他选项见[环境变量说明](docs/development.md#mac-environment-variables)。

旷野之息 1.9.0 的 Mac 构建支持 `DM_GAME_RES=1920x1080`，将场景、HUD 和输出一起提高到真正的 1080p；`DM_GAME_RES=1280x720` 则使用 720p。在用户 `env.txt` 中设置后重启生效。更高分辨率会增加 GPU 耗时，可按清晰度和帧率选择。

## 游玩

**触屏按键。** 点顶部的 **2D** / **3D** 切换布局，App 会记住你的选择。3D 世界和旷野之息默认 3D 布局，其他游戏默认 2D。

```
 ZL  L3*        [−]  2D/3D  [+]        R3*  ZR
 L                                           R
                                         X
  ( 左摇杆 )                           Y   A
             ✚ 十字键*   ( 右摇杆 )*      B
                                  * 只在 3D 布局里
```

连上游戏手柄后，触屏按键会隐藏，手柄上的所有按键都能用。

- **游戏语言**默认英文。想用中文，在 `Documents/env.txt` 里加一行 `DM_LANG=zh-Hans`。
- **存档和日志**在「文件」App 里，App 名字对应的文件夹下：`save/` 和 `log.txt`。出问题时请发 `log.txt`（上一次运行的是 `log.prev.txt`）。
- **第一次进新场景时短暂卡顿**是正常的：App 会为它编译一次图形，下次启动就记住了。
- **重装：** 有些侧载工具重装后会给 App 一个新的数据文件夹。把旧文件夹里的 `save/` 和 `pso_user.tsv` 拷过去，进度就不会丢。
- **不重新打包也能改设置：** 在 `Documents/env.txt` 里写一行一个设置，例如 `DM_OPMODE=0`（掌机模式：分辨率更低、帧率更高）。

## 已知问题

- 没有 amiibo，也没有联网功能。
- 火焰纹章 Engage：切到别的 App 再回来后，部分声音可能一直没有，要重开游戏。
- 超级马力欧 3D 世界：1-1 里可能出现几个小的品红色方块。

## 开发者

工作原理、脚本的全部选项、在 Mac 上运行游戏、添加新游戏、各游戏的技术笔记：[docs/development.md](docs/development.md)。更深入的移植和调试笔记：[docs/agents](docs/agents/README.md)。

## 许可证

MIT（见 [LICENSE](LICENSE)）。第三方代码保留各自的许可证，见 [dm/third_party](dm/third_party/README.md)。
