# Development

The README covers packing and playing. This page is for working on nxnative itself: how it is built, the script's options, running games on the Mac, adding a game, and per-game notes. Agent-oriented details (bring-up failure catalogue, graphics specifics, debugging recipes) are in [docs/agents](agents/README.md).

## How it works

| Part | State |
|---|---|
| Rewriter (`dm/tools/patch_nso.py`, `DM_RULESET=native`) | Runs unchanged on every module of every supported game. Per-build cuts are keyed by the module's build ID |
| Host (`dm/host`) | Stands in for the Horizon kernel and the system services the games call: threads and synchronization, memory, file system with transactional saves, HID, audio, movies (VP9 through libvpx, Vorbis sound through stb_vorbis), software keyboard, focus and lifecycle |
| Graphics (`dm/gfx`) | NVN on Metal. Shaders are extracted by `shader_split.py` from Nintendo's containers and from Unity's `Shader` objects, then translated offline. Mario: 16,266 of 16,268 shaders compile. Engage: 9,268 of 9,269 |
| Audio | Games that carry the SDK's audio renderer (Mario) run it in-process; games that use AudioOut directly (Engage: Wwise) feed it straight. Output goes through Core Audio (default on iOS, `DM_AUDIO=1` on the Mac) |
| Input | iOS: the touch gamepad and physical controllers. Mac: `DM_WINDOW=1` enables keyboard, mouse touch and a physical GameController extended gamepad; scripted input uses `DM_KEYS=<seconds>:<button>,…`, with `DM_KBD=<text>` answering the system keyboard |
| iOS app | One unsigned IPA for iPhone and iPad. The rewritten code is embedded in the executable; the shader libraries, the RomFS and the game icon are inside the app |
| macOS app | `scripts/build_mac_app_from_nsp.py` packages the native AppKit host with rewritten modules, macOS shaders, RomFS, DLC, fonts and icon; local ad-hoc signature, Apple silicon, macOS 26+ |
| Known gaps | Conditional render is always drawn; sparse virtual-pool mappings; `DrawElementsIndirect`. TBDR optimizations are off by default (they don't understand bindless textures yet). No amiibo. The bundled prewarm lists are empty. On the Mac, Mario's menu and dialogue text render blank (fine on the iPhone) |

## The packing script in detail

`scripts/build_ipa_from_nsp.py` (`-h` lists every option):

```
# written to the Desktop with your own home-screen name
python3 scripts/build_ipa_from_nsp.py ~/Games/MarioWonder -k ~/keys/prod.keys -o ~/Desktop/Mario.ipa --app-name "Mario Wonder"

# pack Mario 1.0.0 instead of 1.2.1 (the folder still needs both NSPs: the shader tables cover both versions)
python3 scripts/build_ipa_from_nsp.py ~/Games/MarioWonder -k ~/keys/prod.keys -p v0

# keep the extracted game files (to run the game on the Mac, or to skip extraction next time)
python3 scripts/build_ipa_from_nsp.py ~/Games/MarioWonder -k ~/keys/prod.keys --keep-extracted

# a diagnostic build with environment switches baked in (one KEY=VALUE per line)
python3 scripts/build_ipa_from_nsp.py ~/Games/MarioWonder -k ~/keys/prod.keys --env-file diag_env.txt
```

In Spyder, open the script, fill in the settings at the top (`NSP_DIR`, `PROD_KEYS`, and optionally `PACKAGE`, `OUT_IPA`, `APP_NAME`, `BUNDLE_ID`), and press F5. Empty paths are asked for at run time.

What the script does:
1. It finds the game profile from the title ID (the `[title ID]` in the file names, or the NSP's ticket; the update by its `[vN]` tag).
2. It extracts the NSPs.
3. It rewrites the code modules, checking each build ID against the profile.
4. It splits out the shaders and checks them against the profile's tables.
5. It builds the iOS shader libraries.
6. It calls `build_ipa.sh`.

Everything it writes stays in the NSP folder: intermediate files and logs in `<id>_build/`, the IPA next to the NSPs. The extracted game files are deleted at the end unless you pass `--keep-extracted`. It exits with 0 when done and 1 on an error. The app's bundle ID is `org.nxnative.<base game title ID>` (for example `org.nxnative.0100a6301214e000`); `--app-name` / `--bundle-id` (or `APP_NAME` / `BUNDLE_ID` in Spyder) override the name and ID.

On the device, environment switches go in `Documents/env.txt` (one `KEY=VALUE` per line), and game files are also accepted at `Documents/romfs`.

## Build both platforms from one extraction

When you need a Mac app and an IPA, use the unified entry point:

```
python3 scripts/build_apps_from_nsp.py /Volumes/Games/MarioWonder -k /Volumes/Games/keys/prod.keys --target both
```

The default target is `both`; `--target macos` and `--target ios` select a single platform. Outputs default to the NSP folder and the profile's IPA name, with `.app` for macOS. `-o` / `--out-dir` selects an output **folder**; `--out-app` and `--out-ipa` override the corresponding complete file path. The existing standalone scripts keep their `-o` file-path behavior.

In Spyder, set `NSP_DIR`, `PROD_KEYS` and `TARGET = 'both'` in `scripts/build_apps_from_nsp.py`, save and press F5. `PACKAGE`, `OUT_DIR`, `OUT_APP`, `OUT_IPA`, `APP_NAME`, `BUNDLE_ID`, `KEEP_EXTRACTED` and `DM_ENV_FILE` have matching command-line options. Command-line values override settings. The name, bundle ID, selected game version and diagnostic file apply to both platforms.

The script reuses the standalone scripts' helpers: it builds the extractor once, extracts each required version once, extracts DLC once, rewrites the selected version once and splits shaders once. One `dmsh_build.py` invocation builds the macOS cache and, when iOS is selected, the iOS libraries through `IOSOUT`. Each platform then compiles and packages its own host. Existing shader caches remain in `<title ID>_build/shader/`; shared build logs go in `logs/shared/`, and Mac packaging logs remain in `logs/macos/`. This removes repeated preparation; platform compilation and IPA compression still take their own time. No timing improvement has been measured yet.

Only selected-platform prerequisites are checked. `macos` needs no XcodeGen or iOS build tools; `ios` adds no Mac-app-specific requirements. `both` checks both sets before extraction. A title without a profile still follows the existing survey flow.

Mac packaging runs first, followed by iOS. If either packaging step fails, the other is still attempted. A failed or interrupted run returns a nonzero exit code and keeps extraction and temporary files; completed packages stay available. Retry using `--target` for the failed platform. Only a fully successful run removes `tmp/` and, unless `--keep-extracted` is set, `extract/`. A shared preparation failure stops before platform packaging and likewise retains intermediate files.

The orchestration tests use synthetic inputs and stub compiler/extractor calls:

```
python3 -m unittest discover -s dm/tools/tests -p test_build_apps.py -v
```

## Pack a native Mac app from NSPs

Use the same NSP folder as for an IPA, on the drive holding your game files:

```
python3 scripts/build_mac_app_from_nsp.py /Volumes/Games/MarioWonder -k /Volumes/Games/keys/prod.keys
# Set a different output path and display name:
python3 scripts/build_mac_app_from_nsp.py /Volumes/Games/MarioWonder -k /Volumes/Games/keys/prod.keys -o /Volumes/Games/Mario.app --app-name "Mario Wonder"
```

In Spyder, fill in the new script's `NSP_DIR` and `PROD_KEYS` and press F5. Its settings also include `PACKAGE`, `OUT_APP`, `APP_NAME`, `BUNDLE_ID`, `KEEP_EXTRACTED` and `DM_ENV_FILE`; command-line options override them. `-h` lists all options. The default output replaces the profile's `.ipa` suffix with `.app`, beside the NSPs. Unknown titles use the existing survey flow.

Requires an arm64 Python on Apple silicon, macOS 26+, Xcode with a macOS 26+ SDK and the Metal compiler, .NET SDK 10, zstd, spirv-cross, and Python's lz4, capstone and fonttools. XcodeGen and the iOS SDK are not needed for this script.

The script reuses the IPA script's extraction, build-ID verification, rewriting and shader splitting functions. Shared inputs and caches remain in `<title ID>_build/`; Mac logs go in `logs/macos/`. It requests only macOS shader output, then `dm/macos/tools/package_app.py` builds `make -C dm/host GAME=<id> dmhost_app` and assembles the app. Only runtime `.metallib` and reflection `.json` files enter the app. It reads each library's AIR target and sets both the host's deployment target and `LSMinimumSystemVersion` to at least that version and macOS 26. Cached newer libraries can therefore raise the app's minimum OS. The shader translation chain itself is unchanged.

`dmhost_app` defaults to an optimized Release host: `-O2 -g`, arm64, tuned for Apple M1. Debug symbols remain available for crash analysis. Both Mac entry scripts use this target. For a compiler comparison, override `MACOS_APP_CFLAGS` through the environment or the Make command line; the diagnostic `dmhost` target retains its original `-O1` flags. A compiler optimization change alone does not establish a frame-rate improvement; compare the same game scene, resolution and settings.

For BotW 1.9.0 on Mac, `DM_GAME_RES=1920x1080` selects true 1080p scene rendering, HUD and output; `DM_GAME_RES=1280x720` selects 720p. Restart after changing it. With the variable unset, the game retains its original mode-dependent sizes: handheld 1280x720; docked 1600x900 scene rendering into a 1920x1080 output. The Mac loader applies only the profile's verified build-specific instruction presets before sealing executable pages. It checks all original instructions before changing any and rejects unsupported sizes or builds. Existing D2R `KRES0`/`KRES1` handling remains unchanged. The preset does not apply to iOS.

The packaging and launch setup follow [d2r-mobile's mac_app.sh](https://github.com/jhaizhou-ops/d2r-mobile/blob/46cb318b17e4b75c2e7a45d4256fa79edbfaef1e/dm/tools/mac_app.sh) and [app_mac.m](https://github.com/jhaizhou-ops/d2r-mobile/blob/46cb318b17e4b75c2e7a45d4256fa79edbfaef1e/dm/host/app_mac.m). This script bundles the game resources and code, so the finished app can move independently of the extraction folder. It copies resources using APFS clones where available, validates the plist and verifies its ad-hoc signature before replacing an earlier app with the same bundle ID. Extraction is deleted only after success, unless `--keep-extracted` is given.

At launch, `dm/macos/app_mac.m` locates `Contents/Resources`, enables the native window and sound, and sets these defaults:

- Saves: `~/Library/Application Support/<bundle-id>/save/`.
- Temporary files and learned pipeline list: beside `save/` (`temp/`, `pso_user.tsv`).
- Log: `~/Library/Logs/<bundle-id>/log.txt`, previous run in `log.prev.txt`.
- Diagnostic switches: `env.txt` beside `save/`, taking precedence over the file supplied with `--env-file`; shell environment variables take precedence over both.

For isolated diagnostics, `DM_APP_SUPPORT` and `DM_APP_LOG_DIR` override the support and log directories.

Bundle IDs default to `org.nxnative.<lowercase-title-id>`. Keeping the bundle ID keeps the save location across rebuilds and renames. The app has Quit (⌘Q) and Full Screen (⌃⌘F) menu actions. Keyboard, mouse touch and physical controllers work in the native window. Quit and closing the window use the existing host shutdown routine; this stops host work but does not request an in-game save, so save in the game before quitting. The command-line `dmhost` keeps its existing launch contract and defaults.

### Mac environment variables

For normal play, set only the language and operation mode you want in
`~/Library/Application Support/<bundle-id>/env.txt`, then restart. For example:

```
DM_LANG=zh-Hans
DM_OPMODE=0
```

Shell variables override the user's file, which overrides the app's bundled
`Contents/Resources/dm/env.txt`. Each line is `NAME=value`, without `export`
or shell quotes. The settings below remain supported:

| Variable | Meaning and default |
|---|---|
| `DM_LANG` | Requested game language; `en-US` by default, `zh-Hans` for Simplified Chinese or `zh-Hant` for Traditional Chinese. The game must include that language |
| `DM_OPMODE` | `0` handheld, `1` docked; host default `1`. The game chooses its corresponding rendering settings. The local optimized BotW app bundles `0`, keeping native 1280x720 handheld rendering |
| `DM_PRESENT_LINK` | Presentation route: `0` acquires drawables directly; `1` uses a 60 Hz display link (host default); `2` uses a 120 Hz display link. This is not a game FPS unlock. The local optimized BotW app retains `0` |
| `DM_PRESENT_INTERVAL` | `game` respects the game's interval; `display` overrides it. Defaults to the game profile; leave unset for normal play |
| `DM_LONGFRAME` | Extra long-frame logging is enabled by default; `0` disables it. The local optimized BotW app bundles `0`; periodic timing summaries remain available |
| `DM_APP_SUPPORT`, `DM_APP_LOG_DIR` | Mac app support/log directories; default to the per-bundle Library locations above. Set in the launch environment for isolated tests; these are read before `env.txt` |
| `DM_SAVE`, `DM_TEMP` | Save and temporary directories; the app defaults to `save/` and `temp/` under its support directory |
| `DM_ROOT` | Tool/runtime work root; the Mac app defaults to its support directory |
| `DM_ROMFS`, `DM_MSL_DIR`, `DM_NVN_SHMAP`, `DM_FONT_DIR`, `DM_AOC_DIR` | Resource paths supplied automatically by the app; no manual setup is needed |
| `DM_PSO_USER`, `DM_PSO_MANIFEST` | Override learned and bundled pipeline prewarm lists. Normal play uses the learned list beside `save/` and the bundled manifest |
| `DM_KEYS` | Scripted input for repeatable tests, including both sticks. A non-empty value takes ownership of the controller channel; leave unset when playing with a physical controller |
| `DM_NVN_TSV`, `DM_NVN_SHOT`, `DM_PROBE` | Frame measurements, engine screenshots and instruction probes. These are diagnostic tools; probes can slow the game. See [debugging](agents/05-debugging.md) and [graphics](agents/04-graphics.md) |
| `DM_WINDOW`, `DM_AUDIO` | Native window and audio output; the packaged Mac app supplies both automatically. `dmhost` diagnostics opt in with `1`; `DM_AUDIO=0` selects the silent sink |
| `DM_GAME_RES` | BotW 1.9.0 Mac: `1280x720` or `1920x1080`, including the scene, HUD and output. Unset retains native mode-dependent sizes. The local 1080p app bundles `1920x1080`; a user setting overrides it. D2R retains its existing KRES size parameters |

`DM_GAME` (tools) and `GAME` (Make) select the profile at build time. A packaged
app already contains its profile; these do not switch games at launch.

Mac uniform batching and caches below are automatic. The following local
experiment controls were removed in v3.2; delete their old `env.txt` entries:

| Removed variables | Current behavior |
|---|---|
| `DM_RENDER_SCALE` | The old fractional-scaling patch is removed; use the resolution presets below |
| `DM_NVN_UNIFORM_BATCH`, `DM_NVN_UNIFORM_COPY_SERIAL` | BotW's Mac profile enables batching with independent snapshots; the serial snapshot branch is removed |
| `DM_NVN_RENDER_STATE_CACHE`, `DM_NVN_POOL_CACHE`, `DM_NVN_BINDING_CACHE` | The three Mac caches are automatic |
| `DM_HID_TRACE`, `DM_PROBE_EVERY` | Temporary input tracing and probe throttling are removed; the upstream probe tool remains available |

### BotW Mac resolution presets

Put `DM_GAME_RES=1920x1080` in the Mac app's user `env.txt` for 1080p,
or `DM_GAME_RES=1280x720` for 720p, then restart. Keep `DM_OPMODE` at your
preferred game mode; changing only the resolution retains that mode's effects
and game behavior. Higher resolution increases GPU work, so compare the same
save and view when choosing a preset.

The profile's `mac_resolution_patch` rows cover BotW 1.9.0 main build
`cd57b23fa4bbad65803d9788c01821ee`. They update internal/output widths, output
height and viewport/crop together in the renderer's size setup. The game's
reference widths, dynamic-resolution calculations and timing logic are retained.
The loader changes its private module image; packaged game modules remain
unchanged. No shader-chain change is required.

The earlier `DM_RENDER_SCALE` experiment remains removed. This uses the
existing resolution variable for complete, explicitly supported output sizes.

```sh
make -C dm/host GAME=01007EF00011E000 game_profile
make -C dm/host/tests GAME=01007EF00011E000 build/t_resolution_mac
dm/host/tests/build/t_resolution_mac
python3 -m unittest discover -s dm/tools/tests -p test_game_profile.py
```

### Mac uniform-update batching

BotW's profile enables uniform-update batching automatically on Mac through
`mac_uniform_batch=on`. Other profiles default to `off`; iOS keeps its existing
path. No runtime setting is needed.

The replay prepares immutable GPU copies for a flat sequence of updates to the
same uniform range. Each draw binds its own version; the final updated bytes
are copied back before the next operation. Eligibility requires explicit
read-only shader bindings, private sampled textures, and no vertex/index
buffer alias. Program/state changes, copies, dispatches and command-list
boundaries end the sequence. Unknown or indirect shader access uses the
original ordered-copy path. GPU ordering is preserved and shader libraries are unchanged.

Snapshot preparation uses independent copies of the original binding, followed
by a single barrier and the individual patches. This is equivalent to copying
each previous version because every update replaces the same byte range.
The older serial snapshot implementation has been removed. On Mac, unchanged
viewport, scissor, culling, winding, fill, depth bias/clip, stencil reference
and blend-color values are also cached within each render encoder. Every new
encoder resets the cache.

An M1 Pro headless comparison of BotW 1.9.0 at 960x540, alternating every
180 frames and excluding the first 45 frames of each phase, measured median
frame intervals of 36.0 ms without batching and 19.4 ms with it. Render passes
fell from 377 to 159 while both phases had approximately 4,754 draws per
frame. These are offscreen scene measurements; measure the same foreground
scene to establish displayed frame rate.

At 1280x720, a later comparison against the already-batched serial path measured
19.34 ms median / 21.25 ms p95 without the two optimizations above, and
17.41 ms median / 19.97 ms p95 with them. Four complete alternating phase pairs
contributed 540 frames per side, before an unrelated compiler job began. Both
paths retained the same resolution, shaders and effects, with about 4,750 draws
per frame.

`make -C dm/gfx/tests GAME=01007EF00011E000 t_uniform_batch` builds the GPU
regression test. Run `dm/gfx/tests/t_uniform_batch` to check distinct per-draw
uniform values, query counts, partial writeback, and a following buffer copy.
It also checks every byte of all snapshots in a 94-update batch spanning
multiple arenas. `t_render_state_cache` compares uncached/cached color, depth
and stencil readbacks, plus state changes and encoder resets. Run both tests
with `MTL_DEBUG_LAYER=1` to include Metal API validation.

### Mac buffer binding caches

Mac builds cache repeated memory-pool lookups and skip unchanged Metal buffer
addresses. Both optimizations are automatic on Mac and preserve resolution,
shader code, draw content and game timing.

The pool cache matches the exact address and requested length under the
existing pool mutex. It preserves the last-hit rule for overlapping pools;
adding or removing any pool invalidates the cache. Vertex streams and vertex
shader arguments share one Metal table and one address cache. Fragment
bindings have their own cache. Every new render encoder resets both caches.
Buffer contents are never cached.

With uniform batching and dynamic-state caching already enabled, an M1 Pro
720p BotW comparison alternated these two address caches every 180 frames.
Six complete pairs, excluding the first 45 frames per phase, gave 810 frames
per mode: median frame interval 17.47 to 16.64 ms, p95 19.61 to 19.23 ms,
and median submission CPU time 12.02 to 10.97 ms. Every pair improved its
median frame interval. The p99 remained approximately 22.6 ms, and occasional
long frames remain. These are headless measurements at unchanged quality.

`make -C dm/gfx/tests GAME=01007EF00011E000 t_binding_cache` builds the
regression test. Run `MTL_DEBUG_LAYER=1 dm/gfx/tests/t_binding_cache` to check
overlapping pools, deletion and address reuse, plus GPU readbacks across
binding changes, encoder boundaries and buffer-content updates. The three GPU
regression tests use private controls under `NVN_OPTIMIZATION_TEST` to compare
cached/batched and original paths; production builds expose no such controls.

### Mac physical controllers

Pair a controller in macOS or connect it over USB, then focus the game window. `dm/host/gamepad_mac.m` subscribes to GameController connection/disconnection notifications and samples already-connected extended gamepads at startup. The first supported device supplies the host's single player; connecting another does not replace it, and disconnecting the active one selects a remaining supported device. Non-extended profiles are ignored.

The Mac frontend publishes through `dm_pad_set`, independently of keyboard input. The host merges button bits and selects the greater magnitude for each stick axis. The Mac path sends GameController's A/B/X/Y directly as the game's A/B/X/Y, following [d2r-mobile's controller correction](https://github.com/jhaizhou-ops/d2r-mobile/blob/120fe55c02a5633476998a44f8c3c3c809fa48b0/dm/ios/Sources/dm_gamepad.m): the system already normalizes Nintendo button letters, so another vendor-based swap reverses them twice. PlayStation ×/○/□/△ map to A/B/X/Y. Both sticks use a small radial dead zone.

`dm/host/input_focus_mac.m` observes application activation, window key status, visibility, minimization, fullscreen transitions and display changes. Losing focus clears keyboard, mouse touch and physical input. Regaining focus rereads the connected-controller registry and reinstalls the selected profile's callback, even when the device object is unchanged. A queued refresh handles AppKit notifications arriving before the final key-window state; fullscreen failure delegate methods release the transition state too. All controller callbacks and selection run on the main queue.

`DM_KEYS` diagnostic replays own the same controller channel, so physical controller capture is disabled while a non-empty `DM_KEYS` is set. Windowless runs do not start GameController monitoring. Connected/disconnected device messages appear in the host log. The Mac plist declares the extended-gamepad profile, and both Mac host targets link GameController; the iOS source generator excludes `gamepad_mac.m` by the existing `_mac` convention.

The controller regression test uses Apple's writable snapshot profiles and verifies values returned by the real `GetNpadState` implementation, including mapping, both sticks, keyboard coexistence, disconnect/reconnect and scripted-input ownership. AppKit notifications with simulated app/window state exercise application switching, delayed key restoration, Spaces, fullscreen success/failure, minimization, display changes and callback recovery without opening a window:

```
make -C dm/host/tests GAME=010015100B514000 build/t_gamepad_mac build/t_padmap
dm/host/tests/build/t_gamepad_mac
dm/host/tests/build/t_padmap
```

A physical Xbox controller was also checked in BotW 1.9.0: right-stick input reached the game and live camera-sensitivity changes took effect. Focus recovery is covered by the simulated AppKit tests above. Rebuild an existing app with `--target macos` to include controller support.

## Port another game

Each game has a profile in `dm/games/<id>/`:
- `game.tsv` holds the title ID, known builds, code modules, RomFS marker, memory split, NVN driver tables, app name and bundle ID;
- the shader tables: `shader_map.tsv`, `shader_facts.tsv`, `shader_pairs.tsv`, `c1_full.tsv`, `pso_manifest.tsv`;
- `dmsh_chain.h` holds the chain version.

The shader tools pick a profile with `DM_GAME=<id>`; `make -C dm/host` and `build_ipa.sh` pick it with `GAME=<id>`. Profiles are named after the base game's title ID. There is no default game: without `GAME` / `DM_GAME` the tools stop and list the profiles. `python3 dm/games/game.py list` lists the profiles. Host code that relies on one build's fixed addresses checks that build's ID.

To add a game:
1. Run `scripts/build_ipa_from_nsp.py` on its NSP folder. With no matching profile, it writes a survey to `<title ID>_survey/survey.md`. The survey covers the modules, SDK, engine, containers, rewrite sites, and the imports compared with the host's hooks.
2. Add a profile as described in [dm/games/README.md](../dm/games/README.md).
3. Bring the game up following [docs/agents](agents/README.md): extraction, binary survey, a catalogue of host bring-up failures, graphics, and debugging recipes.

## Build by hand (Mac)

You need the same tools as the script. The shader translator is the prebuilt `dm/gfx/tools/dmsh_xlate_bin`, the build that matches `dmsh_chain.lock`; a fresh `dotnet publish` gives different fingerprints. The commands use three variables:
- `G`, the profile;
- `W`, the game's work folder: `<title ID>-work` inside the game's NSP folder, outside this repository and off the home folder (it grows to the size of the game files);
- `VER`, a version folder named after the NSP version.

```
G=010015100B514000; W="<NSP folder>/$G-work"; VER=v327680
# 1. extract: the base game alone (update -), or an update layered over it (the last argument lets unchanged files become clones)
dotnet build dm/tools/nx_extract -c Release -o $W/build/nx_extract
$W/build/nx_extract/nx_extract <prod.keys> <base NSP> - $W/data/v0
$W/build/nx_extract/nx_extract <prod.keys> <base NSP> <update NSP> $W/data/$VER $W/data/v0/RomFS
# 2. rewrite the profile's code modules
for m in $(python3 dm/games/game.py $G modules); do DM_RULESET=native python3 dm/tools/patch_nso.py $W/data/$VER/ExeFS/$m $W/build/patched_$VER $m; done
# 3. shaders: extract from every version in the profile's shader_versions (comma-separated, base first), then translate into <cache>/b-<chain version>/
DM_GAME=$G python3 dm/gfx/tools/shader_split.py $W/data/v0/RomFS,$W/data/$VER/RomFS $W/data/v0/ExeFS/main,$W/data/$VER/ExeFS/main $W/shader/pkg dm/games/$G/shader_map.tsv dm/games/$G/shader_facts.tsv dm/games/$G/shader_pairs.tsv
DM_GAME=$G python3 dm/gfx/tools/dmsh_chain.py --header
DM_GAME=$G python3 dm/gfx/tools/dmsh_build.py $W/shader/pkg $W/build/cache/metal_shader_cache
python3 dm/gfx/tools/c1_guard.py $W/build/cache/metal_shader_cache/b-<chain version> dm/games/$G/c1_full.tsv
# 4. the host, and the button-icon font for the Nintendo-extension shared font
make -C dm/host GAME=$G dmhost
python3 dm/tools/make_ext_font.py $W/build/font/nintendo_ext.ttf
# 5. run on the Mac
DM_ROOT=$W DM_ROMFS=$W/data/$VER/RomFS DM_SAVE=$W/run/save DM_TEMP=$W/run/temp DM_MSL_DIR=$W/build/cache/metal_shader_cache DM_FONT_DIR=$W/build/font dm/host/dmhost $W/build/patched_$VER
# 6. iOS shader libraries (about 15 min for Mario), then the IPA (default <NSP folder>/<the profile's ipa>)
IOSOUT=$W/build/ios/dmsh_b DM_GAME=$G python3 dm/gfx/tools/dmsh_build.py $W/shader/pkg $W/build/cache/metal_shader_cache
GAME=$G W=$W dm/ios/tools/build_ipa.sh [out.ipa]
```

Notes on these steps:
- `build_ipa.sh` takes the rewritten modules from `$W/build/patched_<package>` and the RomFS from `$W/data/<package>/RomFS`; `PATCHED` and `ROMFS` override them.
- It also bundles a standard font (macOS's Arial Unicode, `STD_FONT=` overrides it) and the generated `nintendo_ext.ttf`.
- The icon is the `icon.jpg` that `nx_extract` saves next to `RomFS/`; `DM_ICON=` points at another image.
- `DM_ENV_FILE=` bakes environment switches into the app, and `DM_DISPLAY_NAME=` renames it.
- If Xcode's Locations setting puts products in a custom place, the script finds the app through the build log.
- hactool cannot read every update (Mario 1.2.1's patch NCA gives "Invalid BKTR layout!"), which is why `nx_extract` uses LibHac.

## Prewarm lists

Metal compiles each combination of shaders and pipeline settings for the GPU the first time it is used. Each takes tens of milliseconds, so a burst of them on entering a level is a visible freeze. The host records what it had to compile and rebuilds those pipelines on a background queue at the next launch:

- `pso_user.tsv` sits next to the save directory: `Documents/pso_user.tsv` on iOS, the parent of `DM_SAVE` on the Mac (`DM_PSO_USER=path` overrides it). It is appended while playing, one line per item built on the spot: a shader (`S`), a render pipeline (`R`, the hex of `pso_skey` in `dm/gfx/nvn/nvn_pso_skey.h`) or a compute pipeline (`C`).
- `dm/games/<id>/pso_manifest.tsv` is the seed list bundled with the app, prewarmed before `pso_user.tsv`.

The lines name shaders by content key and hold no compiled code and nothing personal, so a list recorded on one device works on any other. To seed the bundled list:
1. Record on the Mac with prewarm off, so everything is built on demand: `DM_PSO_MANIFEST=off DM_PSO_RECORD=<file>`, playing the scenes players reach first. Engage's list covers boot, the opening movie, the title, a save load and the prologue battle.
2. Append the recorded lines below the header comments, in the recorded order. Duplicates are dropped at load.
3. Rebuild the IPA.

Record on the game version you ship. At launch the log names each list it read and its line count (`管线预热清单 … 行`), or says that `pso_user.tsv` does not exist yet.

## Game notes

**Super Mario Bros. Wonder (`010015100B514000`)**
- **Versions:** v0 (1.0.0) and 1.2.1 (v327680). With the update layered over v0, unchanged files become APFS clones, so the merged RomFS adds only about 114 MB to the 3.5 GB base.
- **Shaders:** 12,811 in v0 and 16,268 across both versions; the tables hold both.
- **1.2.1:** it is a new `main` build (SDK 16.2.12), whose resource-heap cut (+16 KB slack) was carried over with `dm/tools/nso_fnmap.py`. It also makes new SDK calls, which the host answers: `nn::nfp` finds no amiibo, `pl::IsRunningOnOunce` is false, the shop call is a no-op, and `account::PopOpenUsers` returns none.
- **Mac input:** `DM_KEYS="12:A,14:A,20:A,26:A,32:A"` reaches the opening course.

**Fire Emblem Engage (`0100A6301214E000`)**
- **Engine:** Unity 2020.3 IL2CPP, SDK 12.3.7. The shaders are read out of Unity bundles (`unityfs.py`).
- **Memory:** a 5 GB guest block, the total proven on a phone, with a 2.5 GB application pool. A per-build cut shrinks the SDK's address-region node area to 62 MB.
- **Audio:** Wwise drives AudioOut directly.
- **Movies:** VP9, decoded on the host.
- **60 fps:** the Switch version runs at 30; one patch to its code switches it to the 60 fps timing the game already has, so nothing runs too fast.

**The Legend of Zelda: Breath of the Wild (`01007EF00011E000`)**
- A patch to the game's frame-interval logic lifts its 30 fps limit to 60 without changing the game speed (it falls back to 30 by itself when a frame takes too long).
- The game waits for each frame's GPU work before submitting the next, so the host hands its translated commands to the GPU in segments ([04](agents/04-graphics.md)).
- **Layout capture masks:** R8 captures store their alpha mask in red; RG8 captures store luminance in red and alpha in green. The profile's `alpha_from_red` list selects the layout shaders that receive these channel mappings. This fixes HUD shadow/glow boxes and the solid red rectangles around Game Over text while preserving explicit texture mappings ([04](agents/04-graphics.md)).

**The Legend of Zelda: Link's Awakening (`01006BB00C6F0000`)**
- **Engine:** Grezzo's engine on NintendoWare, SDK 8.2.0 (the oldest so far), NVN 53. Modules main + subsdk0 (GLSLC, NVN's runtime shader compiler) + subsdk1 (movie) + sdk; 9,698 shaders from the bfsha archives, effects and layouts.
- **Window origin:** the only game so far that keeps NVN's default lower-left (OpenGL) window origin; the host flips its viewports and winding and the window image at present ([04](agents/04-graphics.md)). Before that, text the game renders into textures came out upside down.
- **Movies:** VP9 with a 5.1 Vorbis sound track; the host decodes the sound with stb_vorbis.
- **Mac input:** the title wants L+R: `DM_KEYS="f6000:L+R~0.4,f6300:A,f6500:A,f6700:Down,f6800:A"` reaches a new file's name entry (a fresh save directory via `SV=`).
- **Frame rate:** gameplay runs at 60 like on the Switch; the game itself drops to 30 (present interval 2) for event cutscenes.

## Tools (`dm/tools`)

| Tool | What it does |
|---|---|
| `nx_extract/` | NSP → ExeFS / RomFS / icon with LibHac, merging an update over the base game (C#, `dotnet build`). `--manifest` writes ExeFS and a RomFS file list only, for surveys |
| `nso_fnmap.py` | Carries offsets from one build to another (function matching with addresses masked; globals via their references) |
| `nso2elf.py` | Converts NSO to ELF for Ghidra / REA |
| `insn_census.py` | Counts the instruction sites the rewriter must handle |
| `nso_syms.py` | Compares the SDK import surface of two games, or of one game (`-` for the reference) with the host hooks |
| `nvn_slots_got.py` | Builds the NVN fetch table and call sites (GOT-indirect loaders) |
