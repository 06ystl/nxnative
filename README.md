# nxnative

Play your own Nintendo Switch games natively on iPhone, iPad or Mac. Bring your game files and `prod.keys`; the build scripts produce an IPA to sideload or a native Mac app.

It is not an emulator: the game's own code runs directly on the Apple chip, with Switch graphics rebuilt on Metal. Nothing from any game is in this repository, and the project is not affiliated with Nintendo or any game publisher.

## How to play

### With a Mac app

Community projects build on nxnative with Mac apps that turn your games into apps for your iPhone, iPad or Mac, with no command line, and keep them in a library. They are separate projects: questions and bugs about them go to their own pages.

- [NX2Apple](https://github.com/LNPANDY/NX2Apple)
- [NX Play](https://github.com/varyform/nx-native-wrapper)
- [NxNative Launcher](https://github.com/rennan101/nxnative_Launcher)
- [LumaNX](https://github.com/Xc1Ym/LumaNX)

### Build from the command line

You need a Mac with macOS 26.6 or later, [Xcode](https://developer.apple.com/download/all/?q=Xcode%2027.1) 27.1, [Homebrew](https://brew.sh) and Python 3.12 or newer (an arm64 one, not an Intel Homebrew's). An iPhone build also needs Xcode's iOS platform (Xcode → Settings → Components).

The shaders are built with Xcode 27.1's Metal compiler, so take 27.1 from Apple's download page, not the App Store's newer Xcode. With a newer Xcode installed too, rename 27.1 to `Xcode-27.1.app` and select it before step 1: `sudo xcode-select -s /Applications/Xcode-27.1.app`.

**1. Install the tools** (only once), in Terminal:

```
xcodebuild -downloadComponent MetalToolchain
git clone https://github.com/seedds/nxnative.git && cd nxnative
brew install xcodegen zstd glslang
brew install --cask dotnet-sdk
python3 -m pip install lz4 "capstone>=5,<6" fonttools nsz zbic "backports.zstd; python_version < '3.14'"
```

**2. Put your game in a folder**: the game, plus its update and DLC if you have them (`.nsp`, `.xci`, `.nsz` or `.xcz`):

```
~/Games/MarioWonder/
  Super Mario Bros. Wonder [010015100B514000][v0].nsp
  Super Mario Bros. Wonder [010015100B514800][v327680].nsp
```

**3. Build**, with your game folder and your `prod.keys`:

```
python3 scripts/build_ipa_from_nsp.py ~/Games/MarioWonder -k ~/keys/prod.keys
```

The IPA appears in the game's folder. The first build takes 30–60 minutes and needs free disk space of about twice the game's size plus 10 GB; building again is much faster.

The upstream launcher is available with `--platform mac-app`. For this branch's controller and DualSense features, use the custom Mac script below. All options: [The packing script in detail](docs/development.md#the-packing-script-in-detail).

## Build Mac and iOS apps together

To produce both packages, run the shared build script on an Apple silicon Mac with macOS 26.6+ and Xcode 27.1:

```
python3 scripts/build_apps_from_nsp.py /Volumes/Games/MarioWonder -k /Volumes/Games/keys/prod.keys --target both
```

This writes `SMBWMobile.app` and `SMBWMobile.ipa` beside the NSPs. Extraction, code rewriting and shader processing run once for both platforms. Use `--target macos` or `--target ios` for just one. `-o /Volumes/Games/Builds` sets the output folder; `--out-app` and `--out-ipa` set individual output paths.

In Spyder, open `scripts/build_apps_from_nsp.py`, fill in `NSP_DIR` and `PROD_KEYS`, leave `TARGET = 'both'`, save and press F5. Extraction is removed only after all selected packages succeed; `--keep-extracted` keeps it for later builds. If one platform fails during packaging, the script still attempts the other and keeps completed packages and extracted files. Retry with `--target macos` or `--target ios` for the failed platform. The existing separate scripts remain available.

## Pack a Mac app

On an Apple silicon Mac with macOS 26.6+ and Xcode 27.1, use the same NSP folder and keys:

```
python3 scripts/build_mac_app_from_nsp.py /Volumes/Games/MarioWonder -k /Volumes/Games/keys/prod.keys
```

This produces `SMBWMobile.app` beside the NSPs. Double-click it to play; the app includes the game files, macOS shaders and icon, with a local ad-hoc signature. No developer account is needed. In Spyder, set `NSP_DIR` and `PROD_KEYS` at the top of the new script and press F5; `OUT_APP` changes the output path. Keep game files and builds on your game drive.

Mac apps use an optimized Release host (`-O2`) by default. The same setting applies to `--target macos` and `--target both` in the unified script.

Open **Settings…** in the Mac app menu (⌘,) to tune controller rumble, USB audio haptics and adaptive-trigger strength while playing. The Motion tab switches between controller and phone input, shows calibration status, and adjusts horizontal/vertical sensitivity and inversion. Changes save automatically; resolution, frame-rate target and the Metal FPS HUD take effect after restarting. Controller buttons and sticks are held neutral while the panel has focus, while calibration and explicit vibration previews remain available.

Mac input: WASD = left stick, arrows = D-pad, J/K/U/I = A/B/X/Y, Q/E = L/R, Z/C = ZL/ZR, Return/Tab = +/−, F/G = stick presses. Click or drag for touchscreen input. ⌘Q quits; ⌃⌘F toggles full screen.

Physical controllers: pair over Bluetooth or plug in over USB, then keep the game window visible. On multiple displays, a controller continues working while a browser or another app has focus; keyboard and mouse input still require focus in the game. macOS must recognize an extended gamepad (for example Xbox, PlayStation or Switch Pro). The first supported controller controls player 1; connecting or reconnecting while the app runs is supported. Nintendo and Xbox face buttons follow their printed letters; PlayStation uses × = A, ○ = B, □ = X, △ = Y. Both sticks, D-pad, shoulders, triggers, stick clicks and menu/options buttons are mapped. Keyboard input works alongside the controller. Switching apps releases held keyboard/mouse input while retaining controller input in a visible game window. Hiding, minimizing or fully covering the game, leaving its Space, display sleep and inactive user sessions stop controller input, phone motion and rumble. Making the window available again resamples the controller, and full-screen/display changes rebind it as needed. Rebuild older apps with `--target macos` to include these fixes. The input path and focus recovery have regression coverage using Apple's software controller snapshots; physical Xbox right-stick input and camera-sensitivity changes have also been verified in Breath of the Wild.

Controller button prompts on Mac: place a compatible PlayStation UI patch in `patches/dualsense-ui/` beside the game App. It is selected only when the player-1 controller is a DualSense at startup, over USB or Bluetooth. Connect the controller before opening the game. Remove the patch folder and restart to restore original prompts; other controllers and keyboard-only starts also keep the original UI. Changing controllers requires restarting. Button mappings and game controls stay the same.

Controller rumble on Mac: turn on vibration in the game's settings. Newly rebuilt Mac apps send feedback automatically to the selected controller when macOS supports vibration on that connection. Hiding or minimizing the game, display sleep, inactive user sessions, controller disconnection and quitting stop feedback; focusing another app while the game stays visible does not. No environment variables are needed.

If rumble feels weak, put `DM_RUMBLE_GAIN=3` in your Mac `env.txt` and restart. The multiplier accepts any finite nonnegative value: `1` keeps the original strength, `0` mutes, and values such as `20` bring weaker parts of an effect up to full API intensity without extending its duration. Output stays within the system's 0–1 range. It applies to Xbox and other supported controllers.

DualSense USB audio haptics: in Breath of the Wild 1.9.0, set `DM_AUDIO_HAPTICS=1` in the Mac `env.txt` and restart to feel player/NPC footsteps plus selected landing, weapon, bow, explosion, damage, glider, swimming, climbing and ladder effects, with the game’s own volume, filtering and stereo positioning. The capture follows the direct sound path; music, dialogue, menu sounds and shared room-reverb returns are excluded. Nearby NPCs can produce feedback while the player stands still. There is no extra NPC attenuation or combat ducking. `DM_AUDIO_HAPTICS_GAIN` adjusts this separate output (default `0.3`, any finite nonnegative multiplier; try `20` for quiet effects); `DM_RUMBLE_GAIN` does not affect it. A linked stereo peak envelope with 2 ms lookahead reduces waveform flattening when the amplified signal exceeds full scale, retaining left/right balance and allowing full-scale output. This mode replaces ordinary grip rumble on the selected USB DualSense, including combat rumble, while keeping R2/L2 adaptive triggers. Bluetooth and other controllers retain ordinary rumble. Set `DM_AUDIO_HAPTICS=0` and restart to restore ordinary rumble. One connected DualSense is required.

DualSense adaptive triggers on Mac: Breath of the Wild 1.9.0 preloads light R2 resistance when a bow is available. Resistance increases over the full trigger travel, then grows smoothly with the game's charge progress. A verified successful arrow release produces an 80 ms R2 pushback that unloads, then returns to light resistance. Cancelled or empty draws unload without pushback and remain unloaded until the next press. Menus, interrupted draws, loss of the equipped bow and scene exit clear the effect; release R2 before starting a new pull after an interruption. L2 adds moderate resistance while actually guarding with a shield, with a brief increase when a block damages the shield. Merely locking on does not activate it; releasing L2, menus and losing the shield clear it. Both features activate automatically for the selected DualSense on the verified game build; `DM_RUMBLE_GAIN` changes handle vibration, not trigger resistance. USB bow and shield resistance have been confirmed in-game.

Controller motion on Mac: leave `DM_MOTION_SOURCE` unset, or set it to `controller`, to use the selected 1P controller's gyro. Enable motion controls in the game and keep the controller still, buttons facing up, for one second after connection. **Motion → Controller motion connected** confirms calibration; **Calibrate…** resets drift and heading. The controller must provide usable motion data through macOS GameController. Ordinary Xbox controllers and the original GameSir Nova Lite (启明星) have no motion control; a PS4-compatible device name does not add a gyro. An unavailable sensor does not automatically switch to a phone.

Phone motion on Mac: set `DM_MOTION_SOURCE=phone` in your user `env.txt` and restart. An Xbox controller can then supply buttons and sticks while an iPhone supplies gyro input for aiming and motion puzzles. Install [MotionSourceiOS](https://github.com/shiftinv/MotionSourceiOS/releases/tag/v1.1.0) on the phone, connect both devices to the same local network, allow Local Network access, select **Portrait**, leave the accelerometer enabled and tap **Start Server**. In the Mac game's menu bar, choose **Motion → Connect Phone…**, enter the phone's displayed IP address and port (default `26760`), then keep the phone still for one second. **Phone motion connected** confirms calibration. Keep MotionSource in the foreground and the phone screen awake. **Motion → Calibrate…** measures drift and resets the heading; **Disconnect Phone** turns motion off. Saved phone connections reconnect only in `phone` mode. See [phone motion](docs/development.md#mac-phone-motion) for orientation and troubleshooting.

Saves are in `~/Library/Application Support/org.nxnative.<title-id>/save`, logs in `~/Library/Logs/org.nxnative.<title-id>/log.txt` (title ID in lowercase). Put `env.txt` next to `save/` for settings. The minimum OS follows the bundled shader libraries: cached libraries from a newer SDK can raise it above macOS 26. Mac compatibility varies by game; Mario's menu and dialogue text currently render blank.

Rebuilt Mac apps use the shared renderer’s state and buffer caches and immutable uniform snapshots automatically. These optimizations preserve the game's resolution, effects and timing. Use `DM_LANG=zh-Hans` for Simplified Chinese and `DM_OPMODE=0` for handheld mode if desired; restart after changing settings. See the [environment-variable guide](docs/development.md#mac-environment-variables) for the remaining options.

Breath of the Wild 1.9.0 Mac builds support `DM_GAME_RES=1920x1080` for true 1080p scene rendering, HUD and output, or `DM_GAME_RES=1280x720` for 720p. Put the setting in your `env.txt` and restart. Higher resolution uses more GPU time; select the preset that gives you the clarity and frame rate you prefer.

On Mac, Breath of the Wild 1.9.0 also accepts experimental `DM_FPS=90` or `DM_FPS=120` in `env.txt`, followed by a restart. These opt-in modes adapt the game time step to elapsed time and preserve explicit game timing overrides. The default remains 60; the selected value is a ceiling, and actual frame rate depends on the scene, GPU and display. Resolution and effects stay unchanged.

Optional BotW 1.9.0 Mac cheats: put `DM_CHEATS=health,stamina,durability,arrows` in your user `env.txt` and restart. Select only the comma-separated options you want: prevent heart loss, use maximum stamina, refill equipped-item durability to 60000, and prevent arrow consumption. All are off by default; remove the line or use `DM_CHEATS=none` to disable them on restart. Durability changes can be saved with your game; back up the save before using them. The supplied 1.8.2 cheat file cannot be loaded directly. See [cheat details](docs/development.md#botw-mac-cheats).

### Install

Install the IPA on your iPhone or iPad with a sideloading tool such as AltStore, Sideloadly or LiveContainer. If your tool offers **Increased Memory Limit**, turn it on: the bigger games need it.

Game too big to install? Build again with `--romfs separate`, and run the command the script prints once to copy the game files to your phone ([Quick reinstalls](docs/development.md#quick-reinstalls)).

Controls, saves and settings: [Playing](docs/playing.md).

## Games

Games tested on Mac or iPhone. See the [per-game notes](dm/games/README.md#games) for tested platforms, progress and known issues:

Needs iOS / iPadOS 26 or later on an iPhone 15 Pro or newer (A17 Pro chip or later) or an iPad with an M1 chip or later: the games' textures are BC-compressed, and older iPhones can't read that format. Other games aren't supported yet. For them the script writes a survey and still tries its best to pack an IPA, guessing the game's settings; such an IPA may not start.

Under a game, "60 fps with 1.2.0" means it runs at 60 fps (30 on the Switch) with that update.

<!-- gallery: written by dm/tools/docs_gallery.py from docs/images/gallery.tsv; change the table, then run it -->
<table>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/mario-kart-8-deluxe.jpg" width="256" alt="Mario Kart 8 Deluxe"><br><small><b><a href="dm/games/0100152000022000/README.md">Mario Kart 8 Deluxe</a></b><br>no Mii heads</small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/mario-vs-donkey-kong.jpg" width="256" alt="Mario vs. Donkey Kong"><br><small><b><a href="dm/games/0100B99019412000/README.md">Mario vs. Donkey Kong</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/paper-mario-the-thousand-year-door.jpg" width="256" alt="Paper Mario: The Thousand-Year Door"><br><small><b><a href="dm/games/0100ECD018EBE000/README.md">Paper Mario: The Thousand-Year Door</a></b><br>60 fps with 1.0.1</small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/super-mario-3d-world.jpg" width="256" alt="Super Mario 3D World + Bowser's Fury"><br><small><b><a href="dm/games/010028600EBDA000/README.md">Super Mario 3D World + Bowser's Fury</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/super-mario-bros-wonder.jpg" width="256" alt="Super Mario Bros. Wonder"><br><small><b><a href="dm/games/010015100B514000/README.md">Super Mario Bros. Wonder</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/super-mario-galaxy.jpg" width="256" alt="Super Mario Galaxy"><br><small><b><a href="dm/games/010099C022B96000/README.md">Super Mario Galaxy</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/super-mario-galaxy-2.jpg" width="256" alt="Super Mario Galaxy 2"><br><small><b><a href="dm/games/0100FD8022DAA000/README.md">Super Mario Galaxy 2</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/super-mario-odyssey.jpg" width="256" alt="Super Mario Odyssey"><br><small><b><a href="dm/games/0100000000010000/README.md">Super Mario Odyssey</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/zelda-breath-of-the-wild.jpg" width="256" alt="The Legend of Zelda: Breath of the Wild"><br><small><b><a href="dm/games/01007EF00011E000/README.md">The Legend of Zelda: Breath of the Wild</a></b><br>60 fps with 1.9.0</small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/zelda-links-awakening.jpg" width="256" alt="The Legend of Zelda: Link's Awakening"><br><small><b><a href="dm/games/01006BB00C6F0000/README.md">The Legend of Zelda: Link's Awakening</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/zelda-tears-of-the-kingdom.jpg" width="256" alt="The Legend of Zelda: Tears of the Kingdom"><br><small><b><a href="dm/games/0100F2C0115B6000/README.md">The Legend of Zelda: Tears of the Kingdom</a></b><br>60 fps with 1.4.3</small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/13-sentinels.jpg" width="256" alt="13 Sentinels: Aegis Rim"><br><small><b><a href="dm/games/01003FC01670C000/README.md">13 Sentinels: Aegis Rim</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/absolum.jpg" width="256" alt="Absolum"><br><small><b><a href="dm/games/0100A83022A22000/README.md">Absolum</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/ace-attorney-investigations.jpg" width="256" alt="Ace Attorney Investigations Collection"><br><small><b><a href="dm/games/010005501E68C000/README.md">Ace Attorney Investigations Collection</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/advance-wars-1-2-re-boot-camp.jpg" width="256" alt="Advance Wars 1+2: Re-Boot Camp"><br><small><b><a href="dm/games/0100300012F2A000/README.md">Advance Wars 1+2: Re-Boot Camp</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/ai-the-somnium-files.jpg" width="256" alt="AI: THE SOMNIUM FILES"><br><small><b><a href="dm/games/010089B00D09C000/README.md">AI: THE SOMNIUM FILES</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/ai-the-somnium-files-nirvana-initiative.jpg" width="256" alt="AI: THE SOMNIUM FILES - nirvanA Initiative"><br><small><b><a href="dm/games/0100713016CCC000/README.md">AI: THE SOMNIUM FILES - nirvanA Initiative</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/animal-crossing-new-horizons.jpg" width="256" alt="Animal Crossing: New Horizons"><br><small><b><a href="dm/games/01006F8002326000/README.md">Animal Crossing: New Horizons</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/animal-well.png" width="256" alt="ANIMAL WELL"><br><small><b><a href="dm/games/010020D01AD24000/README.md">ANIMAL WELL</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/astral-chain.png" width="256" alt="ASTRAL CHAIN"><br><small><b><a href="dm/games/01007300020FA000/README.md">ASTRAL CHAIN</a></b><br>60 fps target with 1.0.1</small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/balatro.jpg" width="256" alt="Balatro"><br><small><b><a href="dm/games/0100CD801CE5E000/README.md">Balatro</a></b><br>played by touch</small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/ball-x-pit.jpg" width="256" alt="BALL x PIT"><br><small><b><a href="dm/games/010086A022444000/README.md">BALL x PIT</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/bayonetta.jpg" width="256" alt="Bayonetta"><br><small><b><a href="dm/games/010076F0049A2000/README.md">Bayonetta</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/bayonetta-2.jpg" width="256" alt="Bayonetta 2"><br><small><b><a href="dm/games/01007960049A0000/README.md">Bayonetta 2</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/bayonetta-3.jpg" width="256" alt="Bayonetta 3"><br><small><b><a href="dm/games/01004A4010FEA000/README.md">Bayonetta 3</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/big-brain-academy-brain-vs-brain.jpg" width="256" alt="Big Brain Academy: Brain vs. Brain"><br><small><b><a href="dm/games/0100620012D6E000/README.md">Big Brain Academy: Brain vs. Brain</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/brain-memory-training-academy.jpg" width="256" alt="Brain Memory Training Academy"><br><small><b><a href="dm/games/0100F5D01DA3A000/README.md">Brain Memory Training Academy</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/captain-toad-treasure-tracker.jpg" width="256" alt="Captain Toad: Treasure Tracker"><br><small><b><a href="dm/games/01009BF0072D4000/README.md">Captain Toad: Treasure Tracker</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/catherine-full-body.jpg" width="256" alt="Catherine: Full Body"><br><small><b><a href="dm/games/0100BF00112C0000/README.md">Catherine: Full Body</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/celeste.jpg" width="256" alt="Celeste"><br><small><b><a href="dm/games/01002B30028F6000/README.md">Celeste</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/cuphead.jpg" width="256" alt="Cuphead"><br><small><b><a href="dm/games/0100A5C00D162000/README.md">Cuphead</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/dark-souls-remastered-creation.jpg" width="256" alt="DARK SOULS: REMASTERED"><br><small><b><a href="dm/games/01004AB00A260000/README.md">DARK SOULS: REMASTERED</a></b><br>60 fps with 1.0.3</small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/digimon-story-cyber-sleuth.jpg" width="256" alt="Digimon Story Cyber Sleuth: Complete Edition"><br><small><b><a href="dm/games/010014E00DB56000/README.md">Digimon Story Cyber Sleuth: Complete Edition</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/donkey-kong-country-tropical-freeze.jpg" width="256" alt="Donkey Kong Country: Tropical Freeze"><br><small><b><a href="dm/games/0100C1F0051B6000/README.md">Donkey Kong Country: Tropical Freeze</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/dragon-quest-vii-reimagined.jpg" width="256" alt="DRAGON QUEST VII Reimagined"><br><small><b><a href="dm/games/0100A9D01C446000/README.md">DRAGON QUEST VII Reimagined</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/dragon-quest-xi-s.jpg" width="256" alt="DRAGON QUEST XI S: Echoes of an Elusive Age – Definitive Edition"><br><small><b><a href="dm/games/01006C300E9F0000/README.md">DRAGON QUEST XI S: Echoes of an Elusive Age – Definitive Edition</a></b><br>60 fps with 1.0.4</small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/final-fantasy-resonance.jpg" width="256" alt="FINAL FANTASY RESONANCE"><br><small><b><a href="dm/games/0100606026F12000/README.md">FINAL FANTASY RESONANCE</a></b><br>60 fps with 1.0.1</small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/final-fantasy-tactics.jpg" width="256" alt="FINAL FANTASY TACTICS - The Ivalice Chronicles"><br><small><b><a href="dm/games/010038B015560000/README.md">FINAL FANTASY TACTICS - The Ivalice Chronicles</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/fire-emblem-engage.jpg" width="256" alt="Fire Emblem Engage"><br><small><b><a href="dm/games/0100A6301214E000/README.md">Fire Emblem Engage</a></b><br>60 fps with 2.0.0</small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/fire-emblem-three-houses.jpg" width="256" alt="Fire Emblem: Three Houses"><br><small><b><a href="dm/games/010055D009F78000/README.md">Fire Emblem: Three Houses</a></b><br>60 fps with 1.2.0</small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/ghost-trick-phantom-detective.jpg" width="256" alt="Ghost Trick: Phantom Detective"><br><small><b><a href="dm/games/010029B018432000/README.md">Ghost Trick: Phantom Detective</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/the-great-ace-attorney-chronicles.jpg" width="256" alt="The Great Ace Attorney Chronicles"><br><small><b><a href="dm/games/010036E00FB20000/README.md">The Great Ace Attorney Chronicles</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/hades.jpg" width="256" alt="Hades"><br><small><b><a href="dm/games/0100535012974000/README.md">Hades</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/hades-ii.jpg" width="256" alt="Hades II"><br><small><b><a href="dm/games/0100A00019DE0000/README.md">Hades II</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/hollow-knight-silksong.jpg" width="256" alt="Hollow Knight: Silksong"><br><small><b><a href="dm/games/010013C00E930000/README.md">Hollow Knight: Silksong</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/hyrule-warriors-age-of-calamity.jpg" width="256" alt="Hyrule Warriors: Age of Calamity"><br><small><b><a href="dm/games/01002B00111A2000/README.md">Hyrule Warriors: Age of Calamity</a></b><br>60 fps with 1.3.0</small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/kirby-and-the-forgotten-land.jpg" width="256" alt="Kirby and the Forgotten Land"><br><small><b><a href="dm/games/01004D300C5AE000/README.md">Kirby and the Forgotten Land</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/luigis-mansion-3.jpg" width="256" alt="Luigi's Mansion 3"><br><small><b><a href="dm/games/0100DCA0064A6000/README.md">Luigi's Mansion 3</a></b><br>60 fps with 1.4.0</small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/metroid-dread.jpg" width="256" alt="Metroid Dread"><br><small><b><a href="dm/games/010093801237C000/README.md">Metroid Dread</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/monster-hunter-rise.jpg" width="256" alt="Monster Hunter Rise"><br><small><b><a href="dm/games/0100B04011742000/README.md">Monster Hunter Rise</a></b><br>60 fps with 16.0.2</small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/monster-train-2.jpg" width="256" alt="Monster Train 2"><br><small><b><a href="dm/games/010051701FB46000/README.md">Monster Train 2</a></b><br>60 fps with 1.1.1</small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/octopath-traveler.jpg" width="256" alt="OCTOPATH TRAVELER"><br><small><b><a href="dm/games/010057D006492000/README.md">OCTOPATH TRAVELER</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/octopath-traveler-0.jpg" width="256" alt="Octopath Traveler 0"><br><small><b><a href="dm/games/01005270232F2000/README.md">Octopath Traveler 0</a></b><br>60 fps with 1.0.5</small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/octopath-traveler-ii.jpg" width="256" alt="Octopath Traveler II"><br><small><b><a href="dm/games/0100A3501946E000/README.md">Octopath Traveler II</a></b><br>60 fps with 1.1.1</small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/patricks-parabox.jpg" width="256" alt="Patrick's Parabox"><br><small><b><a href="dm/games/0100E44016C22000/README.md">Patrick's Parabox</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/persona-5-royal.jpg" width="256" alt="Persona 5 Royal"><br><small><b><a href="dm/games/01005CA01580E000/README.md">Persona 5 Royal</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/pikmin-4.jpg" width="256" alt="Pikmin 4"><br><small><b><a href="dm/games/0100B7C00933A000/README.md">Pikmin 4</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/pokemon-brilliant-diamond.jpg" width="256" alt="Pokémon Brilliant Diamond"><br><small><b><a href="dm/games/0100000011D90000/README.md">Pokémon Brilliant Diamond</a></b><br>60 fps with 1.3.0</small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/pokemon-legends-z-a.jpg" width="256" alt="Pokémon Legends: Z-A"><br><small><b><a href="dm/games/0100F43008C44000/README.md">Pokémon Legends: Z-A</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/pokemon-scarlet.png" width="256" alt="Pokémon Scarlet"><br><small><b><a href="dm/games/0100A3D008C5C000/README.md">Pokémon Scarlet</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/pokemon-violet.jpg" width="256" alt="Pokémon Violet"><br><small><b><a href="dm/games/01008F6008C5E000/README.md">Pokémon Violet</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/pokemon-sword.jpg" width="256" alt="Pokémon Sword"><br><small><b><a href="dm/games/0100ABF008968000/README.md">Pokémon Sword</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/pokemon-shield.jpg" width="256" alt="Pokémon Shield"><br><small><b><a href="dm/games/01008DB008C2C000/README.md">Pokémon Shield</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/portal.jpg" width="256" alt="Portal"><br><small><b><a href="dm/games/01007BB017812000/README.md">Portal</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/raging-loop.jpg" width="256" alt="Raging Loop"><br><small><b><a href="dm/games/010020400E1C2000/README.md">Raging Loop</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/rhythm-heaven-groove.jpg" width="256" alt="Rhythm Heaven Groove"><br><small><b><a href="dm/games/0100D9F01D474000/README.md">Rhythm Heaven Groove</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/romance-of-the-three-kingdoms-8-remake.jpg" width="256" alt="ROMANCE OF THE THREE KINGDOMS 8 REMAKE"><br><small><b><a href="dm/games/0100C2A01A730000/README.md">ROMANCE OF THE THREE KINGDOMS 8 REMAKE</a></b><br>controller only</small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/sea-of-stars.jpg" width="256" alt="Sea of Stars"><br><small><b><a href="dm/games/01008C0016544000/README.md">Sea of Stars</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/shin-megami-tensei-v-vengeance.jpg" width="256" alt="SHIN MEGAMI TENSEI V: Vengeance"><br><small><b><a href="dm/games/010069C01AB82000/README.md">SHIN MEGAMI TENSEI V: Vengeance</a></b><br>60 fps with 1.0.3</small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/stardew-valley.jpg" width="256" alt="Stardew Valley"><br><small><b><a href="dm/games/0100E65002BB8000/README.md">Stardew Valley</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/steins-gate-reboot.jpg" width="256" alt="STEINS;GATE RE:BOOT"><br><small><b><a href="dm/games/01008BC024FDE000/README.md">STEINS;GATE RE:BOOT</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/super-smash-bros-ultimate.jpg" width="256" alt="Super Smash Bros. Ultimate"><br><small><b><a href="dm/games/01006A800016E000/README.md">Super Smash Bros. Ultimate</a></b><br>offline</small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/taiko-risshiden-v-dx.jpg" width="256" alt="Taiko Risshiden V DX"><br><small><b><a href="dm/games/0100346017304000/README.md">Taiko Risshiden V DX</a></b><br>Japanese · played by touch</small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/unicorn-overlord.jpg" width="256" alt="Unicorn Overlord"><br><small><b><a href="dm/games/010069401ADB8000/README.md">Unicorn Overlord</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/yoshis-crafted-world.jpg" width="256" alt="Yoshi's Crafted World"><br><small><b><a href="dm/games/01006000040C2000/README.md">Yoshi's Crafted World</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/nier-automata.png" width="256" alt="NieR:Automata The End of YoRHa Edition"><br><small><b><a href="dm/games/010056B015FE8000/README.md">NieR:Automata The End of YoRHa Edition</a></b><br>60 fps with 1.0.3</small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/zelda-echoes-of-wisdom.jpg" width="256" alt="The Legend of Zelda: Echoes of Wisdom"><br><small><b><a href="dm/games/01008CF01BAAC000/README.md">The Legend of Zelda: Echoes of Wisdom</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/donkey-kong-country-returns-hd.png" width="256" alt="Donkey Kong Country Returns HD"><br><small><b><a href="dm/games/01009D901BC56000/README.md">Donkey Kong Country Returns HD</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/mario-rabbids-sparks-of-hope.jpg" width="256" alt="Mario + Rabbids Sparks of Hope"><br><small><b><a href="dm/games/0100317013770000/README.md">Mario + Rabbids Sparks of Hope</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/xenoblade-chronicles-2.jpg" width="256" alt="Xenoblade Chronicles 2"><br><small><b><a href="dm/games/0100E95004038000/README.md">Xenoblade Chronicles 2</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/xenoblade-chronicles-3.jpg" width="256" alt="Xenoblade Chronicles 3"><br><small><b><a href="dm/games/010074F013262000/README.md">Xenoblade Chronicles 3</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/final-fantasy-crystal-chronicles.jpg" width="256" alt="FINAL FANTASY CRYSTAL CHRONICLES Remastered Edition"><br><small><b><a href="dm/games/0100CE4010AAC000/README.md">FINAL FANTASY CRYSTAL CHRONICLES Remastered Edition</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/return-of-the-obra-dinn.png" width="256" alt="Return of the Obra Dinn"><br><small><b><a href="dm/games/010032E00E6E2000/README.md">Return of the Obra Dinn</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/blasphemous-2.png" width="256" alt="Blasphemous 2"><br><small><b><a href="dm/games/010040801A4C8000/README.md">Blasphemous 2</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/silver-pines.jpg" width="256" alt="Silver Pines"><br><small><b><a href="dm/games/0100D5B026844000/README.md">Silver Pines</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/blasphemous.jpg" width="256" alt="Blasphemous"><br><small><b><a href="dm/games/0100698009C6E000/README.md">Blasphemous</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/final-fantasy-x-x2-hd-remaster.jpg" width="256" alt="FINAL FANTASY X/X-2 HD Remaster"><br><small><b><a href="dm/games/0100BC300CB48000/README.md">FINAL FANTASY X/X-2 HD Remaster</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/mario-rabbids-kingdom-battle.jpg" width="256" alt="Mario + Rabbids Kingdom Battle"><br><small><b><a href="dm/games/010067300059A000/README.md">Mario + Rabbids Kingdom Battle</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/persona-4-golden.jpg" width="256" alt="Persona 4 Golden"><br><small><b><a href="dm/games/010062B01525C000/README.md">Persona 4 Golden</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/xenoblade-chronicles-definitive-edition.jpg" width="256" alt="Xenoblade Chronicles: Definitive Edition"><br><small><b><a href="dm/games/0100FF500E34A000/README.md">Xenoblade Chronicles: Definitive Edition</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/pokemon-legends-arceus.jpg" width="256" alt="Pokémon Legends: Arceus"><br><small><b><a href="dm/games/01001F5010DFA000/README.md">Pokémon Legends: Arceus</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/super-mario-party-jamboree.jpg" width="256" alt="Super Mario Party Jamboree"><br><small><b><a href="dm/games/0100965017338000/README.md">Super Mario Party Jamboree</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/cult-of-the-lamb.jpg" width="256" alt="Cult of the Lamb"><br><small><b><a href="dm/games/01002E7016C46000/README.md">Cult of the Lamb</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/paper-mario-the-origami-king.jpg" width="256" alt="Paper Mario: The Origami King"><br><small><b><a href="dm/games/0100A3900C3E2000/README.md">Paper Mario: The Origami King</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/batman-arkham-knight.jpg" width="256" alt="Batman: Arkham Knight"><br><small><b><a href="dm/games/0100ACD0163D0000/README.md">Batman: Arkham Knight</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/bastion.jpg" width="256" alt="Bastion"><br><small><b><a href="dm/games/010038600B27E000/README.md">Bastion</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/baba-is-you.jpg" width="256" alt="Baba Is You"><br><small><b><a href="dm/games/01002CD00A51C000/README.md">Baba Is You</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/steamworld-heist-ii.jpg" width="256" alt="SteamWorld Heist II"><br><small><b><a href="dm/games/010089C01E9CA000/README.md">SteamWorld Heist II</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/steamworld-heist.jpg" width="256" alt="SteamWorld Heist: Ultimate Edition"><br><small><b><a href="dm/games/010016100A186000/README.md">SteamWorld Heist: Ultimate Edition</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/subnautica-below-zero.jpg" width="256" alt="Subnautica: Below Zero"><br><small><b><a href="dm/games/010014C011146000/README.md">Subnautica: Below Zero</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/steamworld-dig-2.jpg" width="256" alt="SteamWorld Dig 2"><br><small><b><a href="dm/games/0100CA9002322000/README.md">SteamWorld Dig 2</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/streets-of-rage-4.jpg" width="256" alt="Streets of Rage 4"><br><small><b><a href="dm/games/0100EC9010258000/README.md">Streets of Rage 4</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/mario-party-superstars.jpg" width="256" alt="Mario Party Superstars"><br><small><b><a href="dm/games/01006FE013472000/README.md">Mario Party Superstars</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/subnautica.jpg" width="256" alt="Subnautica"><br><small><b><a href="dm/games/0100429011144000/README.md">Subnautica</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/steamworld-dig.jpg" width="256" alt="SteamWorld Dig"><br><small><b><a href="dm/games/01009320084A4000/README.md">SteamWorld Dig</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/team-sonic-racing.jpg" width="256" alt="Team Sonic Racing"><br><small><b><a href="dm/games/010092B0091D0000/README.md">Team Sonic Racing</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/well-dweller.jpg" width="256" alt="Well Dweller"><br><small><b><a href="dm/games/0100217023F6C000/README.md">Well Dweller</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/need-for-speed-hot-pursuit-remastered.jpg" width="256" alt="Need for Speed: Hot Pursuit Remastered"><br><small><b><a href="dm/games/010029B0118E8000/README.md">Need for Speed: Hot Pursuit Remastered</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/ea-sports-fc-27.jpg" width="256" alt="EA SPORTS FC 27"><br><small><b><a href="dm/games/0100C49025D3E000/README.md">EA SPORTS FC 27</a></b><br>60 fps with 1.8d.310c</small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/portal-2.jpg" width="256" alt="Portal 2"><br><small><b><a href="dm/games/0100ABD01785C000/README.md">Portal 2</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/super-monkey-ball-banana-rumble.jpg" width="256" alt="Super Monkey Ball Banana Rumble"><br><small><b><a href="dm/games/010031F019294000/README.md">Super Monkey Ball Banana Rumble</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/atelier-ryza-dx.jpg" width="256" alt="Atelier Ryza: Ever Darkness &amp; the Secret Hideout DX"><br><small><b><a href="dm/games/0100199023B2E000/README.md">Atelier Ryza: Ever Darkness &amp; the Secret Hideout DX</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/dragon-quest-iii-hd-2d-remake.jpg" width="256" alt="DRAGON QUEST III HD-2D Remake"><br><small><b><a href="dm/games/01003E601E324000/README.md">DRAGON QUEST III HD-2D Remake</a></b></small></td>
<td align="center" valign="top" width="33%"><img src="docs/images/hyrule-warriors-definitive-edition.jpg" width="256" alt="Hyrule Warriors: Definitive Edition"><br><small><b><a href="dm/games/0100AE00096EA000/README.md">Hyrule Warriors: Definitive Edition</a></b></small></td>
</tr>
<tr>
<td align="center" valign="top" width="33%"><img src="docs/images/metroid-prime-remastered.jpg" width="256" alt="Metroid Prime Remastered"><br><small><b><a href="dm/games/010012101468C000/README.md">Metroid Prime Remastered</a></b></small></td>
<td></td>
<td></td>
</tr>
</table>
<!-- end of gallery -->

### For developers

[How it works](docs/development.md) · [Game notes](dm/games/README.md#games) · [Bring-up and debugging](docs/agents/README.md) · [Front ends](docs/frontends.md) · [Contributing](CONTRIBUTING.md)

### Acknowledgements

nxnative started from **[d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile)** (MIT), which developed this native-execution approach for Diablo II: Resurrected: its NSO rewriter, Horizon host, NVN-on-Metal layer and iOS app shell. Fixes go both ways. It also builds on **Ryujinx** (MIT; its shader translator, in `dm/third_party/ryujinx` with [a few fixes](dm/third_party/ryujinx/README.md), and a reference for system services), **[Atmosphère](https://github.com/Atmosphere-NX/Atmosphere)** (Horizon's synchronization semantics), **yuzu** (Maxwell encodings, kernel cross-checks), **[LibHac](https://github.com/Thealexbarney/LibHac)** and **hactool** (reading NSPs), **[SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross)** and **[glslang](https://github.com/KhronosGroup/glslang)** (shaders to Metal), **deko3d** (zlib; texture layout sizes), **libvpx**, **stb_vorbis**, the **Vulkan headers** and **NVIDIA FLIP** ([licenses](dm/third_party/README.md)), and **Capstone**, **lz4**, **fontTools** and **XcodeGen** in the build.

### License

MIT ([LICENSE](LICENSE)). Third-party code keeps its own license ([dm/third_party](dm/third_party/README.md)).

---

# 中文说明

在 iPhone、iPad 或 Mac 上原生运行你自己的 Nintendo Switch 游戏。准备好游戏文件和 `prod.keys`，用脚本打包后安装。

游戏自己的代码直接运行在苹果芯片上，图形通过 Metal 重建。本仓库不含游戏内容，与任天堂及游戏发行商无关。

## 开始游玩

[NX2Apple](https://github.com/LNPANDY/NX2Apple)、[NX Play](https://github.com/varyform/nx-native-wrapper)、[NxNative Launcher](https://github.com/rennan101/nxnative_Launcher) 和 [LumaNX](https://github.com/Xc1Ym/LumaNX) 提供图形化游戏库和构建入口。这些是独立项目，相关问题请向各自项目反馈。

命令行构建需要 Apple 芯片 Mac、macOS 26.6 或更新版本、[Xcode 27.1](https://developer.apple.com/download/all/?q=Xcode%2027.1)、[Homebrew](https://brew.sh) 和原生 arm64 Python 3.12 或更新版本。iPhone 构建还需要 Xcode 的 iOS 平台组件。着色器依赖指定的 Metal 编译器；若同时安装更新版 Xcode，将 27.1 命名为 `Xcode-27.1.app`，先执行 `sudo xcode-select -s /Applications/Xcode-27.1.app`。

**1. 安装工具**（只需一次）：

```
xcodebuild -downloadComponent MetalToolchain
git clone https://github.com/seedds/nxnative.git && cd nxnative
brew install xcodegen zstd glslang
brew install --cask dotnet-sdk
python3 -m pip install lz4 "capstone>=5,<6" fonttools nsz zbic "backports.zstd; python_version < '3.14'"
```

**2. 将同一个游戏的本体、更新和 DLC 放在一个文件夹**（支持 `.nsp`、`.xci`、`.nsz`、`.xcz`）：

```
~/Games/MarioWonder/
  Super Mario Bros. Wonder [010015100B514000][v0].nsp
  Super Mario Bros. Wonder [010015100B514800][v327680].nsp
```

**3. 构建**：

```
python3 scripts/build_ipa_from_nsp.py ~/Games/MarioWonder -k ~/keys/prod.keys
```

IPA 出现在游戏文件夹中。首次构建通常需要 30–60 分钟，空闲空间约为游戏大小的两倍再加 10 GB；后续构建会复用缓存。上游 Mac 启动器可使用 `--platform mac-app`；本分支的手柄与 DualSense 功能请使用下面的 Mac 脚本。[完整选项](docs/development.md#the-packing-script-in-detail)。

## 一次构建 Mac 和 iOS 安装包

需要两种安装包时，在装有 macOS 26.6+、Xcode 27.1 的 Apple 芯片 Mac 上运行统一构建脚本：

```
python3 scripts/build_apps_from_nsp.py /Volumes/Games/MarioWonder -k /Volumes/Games/keys/prod.keys --target both
```

脚本会在 NSP 旁生成 `SMBWMobile.app` 和 `SMBWMobile.ipa`。解包、代码改写和着色器处理共用一次。只需要一种时，使用 `--target macos` 或 `--target ios`。`-o /Volumes/Games/Builds` 设置输出文件夹；`--out-app` 和 `--out-ipa` 分别指定完整输出路径。

在 Spyder 中打开 `scripts/build_apps_from_nsp.py`，填写 `NSP_DIR`、`PROD_KEYS`，保留 `TARGET = 'both'`，保存后按 F5。只有所选安装包全部成功后才删除解包文件；使用 `--keep-extracted` 可以留待下次构建。某个平台打包失败时，脚本仍会尝试另一个平台，并保留已完成的安装包和解包文件；可以用 `--target macos` 或 `--target ios` 重试失败的平台。原来的两个独立脚本仍可使用。

## 打包 Mac App

在装有 macOS 26.6+、Xcode 27.1 的 Apple 芯片 Mac 上，使用同样的 NSP 文件夹和密钥：

```
python3 scripts/build_mac_app_from_nsp.py /Volumes/Games/MarioWonder -k /Volumes/Games/keys/prod.keys
```

脚本会在 NSP 旁生成 `SMBWMobile.app`，双击即可启动；包内包含游戏文件、macOS 着色器和图标，并使用本地临时签名，无需开发者账号。在 Spyder 中填写新脚本顶部的 `NSP_DIR`、`PROD_KEYS` 后按 F5；`OUT_APP` 可以更改输出路径。游戏文件和构建产物请放在存放游戏的磁盘上。

Mac App 默认使用优化的 Release 宿主（`-O2`）。统一脚本的 `--target macos` 和 `--target both` 也使用这一设置。

在 Mac 应用菜单选择**设置…**（⌘,），可在游玩时调整普通震动、USB 音频触觉和自适应扳机阻力。“体感”页可切换手柄／手机来源、查看校准状态，并调整水平／垂直灵敏度与反转。更改自动保存；分辨率、帧率目标和 Metal FPS 显示在重启游戏后生效。面板获得焦点时，手柄按键与摇杆暂停传给游戏，仍可校准和主动预览震动。

Mac 键位：WASD = 左摇杆，方向键 = 十字键，J/K/U/I = A/B/X/Y，Q/E = L/R，Z/C = ZL/ZR，Return/Tab = +/−，F/G = 按下左右摇杆。鼠标单击或拖动模拟触屏。⌘Q 退出，⌃⌘F 切换全屏。

实体手柄：通过蓝牙配对或 USB 连接后，保持游戏窗口可见。使用多个显示器时，即使浏览器或其他应用获得焦点，手柄仍可控制游戏；键盘和鼠标输入仍要求游戏获得焦点。手柄需被 macOS 识别为完整游戏手柄，例如 Xbox、PlayStation 或 Switch Pro。第一个支持的手柄控制 1P，支持运行中连接和重新连接。任天堂和 Xbox 手柄的面键按键帽字母映射；PlayStation 对应 × = A、○ = B、□ = X、△ = Y。双摇杆、十字键、肩键、扳机、摇杆按下和菜单／选项键均已映射，键盘可以同时使用。切换应用会释放按住的键盘／鼠标输入，可见游戏窗口的手柄输入保持有效。游戏隐藏、最小化、被完全遮挡、离开其所在桌面、显示器休眠或用户会话停用时，会停止手柄输入、手机体感和震动；窗口恢复可用后会重新采样手柄，全屏及显示器切换也会按需重新绑定。旧版 App 请用 `--target macos` 重新构建以包含这些修复。输入通路与焦点恢复已用苹果的软件手柄快照做回归测试；实体 Xbox 手柄的右摇杆输入及视角灵敏度修改也已在旷野之息中验证。

Mac 手柄按键提示：把兼容的 PlayStation UI 补丁放到游戏 App 同级的 `patches/dualsense-ui/`。只有启动时主手柄为 DualSense 才会启用，支持 USB 和蓝牙，请先连接手柄再打开游戏。移走补丁文件夹并重启即可恢复原版；其他手柄或仅键盘启动时也使用原版 UI。换手柄后需要重启游戏，按键映射和游戏操作保持原样。

Mac 手柄震动：在游戏设置中打开震动。重新构建的 Mac App 会自动向当前手柄发送反馈，需要 macOS 支持该手柄在当前连接方式下的震动功能。隐藏或最小化游戏、显示器休眠、用户会话停用、断开手柄或退出时会停止震动；游戏仍可见时，切换到其他应用不会停止震动，无需设置环境变量。

如果震动偏弱，可在 Mac 用户 `env.txt` 中设置 `DM_RUMBLE_GAIN=3` 后重启。倍率接受任意非负有限数值：`1` 保持原有强度，`0` 关闭震动，`20` 等更高倍率可让效果中较弱的片段也达到接口满强度，不延长震动时长。输出仍在系统允许的 0–1 范围内。此参数对 Xbox 和其他受支持的手柄均生效。

DualSense USB 音频触觉：《旷野之息》1.9.0 可在 Mac `env.txt` 中设置 `DM_AUDIO_HAPTICS=1`，重启后通过握把感受玩家与 NPC 脚步，以及已接入的落地、武器、弓箭、爆炸、受击、滑翔伞、游泳、攀爬和梯子音效，沿用游戏自身的音量、滤波和左右声像。提取的是直接声音，不包含音乐、对白、菜单音效和公共混响返回；玩家站着不动时，附近 NPC 的脚步也能产生反馈。不额外压低 NPC 或战斗期间的脚步。`DM_AUDIO_HAPTICS_GAIN` 单独调整强度（默认 `0.3`，接受任意非负有限倍率；轻音效可试 `20`），不受 `DM_RUMBLE_GAIN` 影响。左右声道共用带2毫秒前瞻的峰值包络，在放大后的信号超过满幅时减少波形削平，保留左右比例并允许满幅输出。此模式替代选中 USB DualSense 的普通握把震动，包括战斗震动，R2/L2 自适应扳机继续工作。蓝牙和其他手柄保留普通震动。设为 `DM_AUDIO_HAPTICS=0` 后重启即可恢复普通震动。需要只连接一只 DualSense。

Mac DualSense 自适应扳机：《旷野之息》1.9.0 会在有弓可用时预先设置轻阻力，R2 扣得越深阻力越大，再随游戏中的蓄力进度平滑加重。确认成功射出箭后，R2 产生约80毫秒的回推并卸力，再恢复轻阻力。取消拉弓或空箭时直接卸力，保持到下次扣动。打开菜单、拉弓被打断、失去已装备的弓或退出场景时解除效果，中断后需要松开 R2 再重新扣动。L2 在实际举盾防御时提供适度阻力，挡住攻击并造成盾牌损耗时短暂加重。单纯锁定不会启用；松开 L2、打开菜单或失去盾牌时解除。在已验证的游戏版本上，选中的 DualSense 会自动启用这两项功能；`DM_RUMBLE_GAIN` 只调整握把震动，不影响扳机阻力。USB 拉弓与举盾阻力已在游戏内确认。

Mac 手柄体感：不填写 `DM_MOTION_SOURCE`，或设为 `controller`，即可使用当前 1P 手柄的陀螺仪。在游戏设置中启用体感控制，连接后让手柄按键朝上静止一秒。**Motion → Controller motion connected** 表示校准完成；**Calibrate…** 可重新测量漂移并重置朝向。手柄必须通过 macOS GameController 提供可用运动数据。普通 Xbox 手柄及初代盖世小鸡启明星（Nova Lite）没有体感功能；显示为 PS4 兼容设备也不会增加陀螺仪。传感器不可用时不会自动切换到手机。

Mac 手机体感：在用户 `env.txt` 中设置 `DM_MOTION_SOURCE=phone` 后重启。此时可以用 Xbox 手柄负责按键和摇杆，同时用 iPhone 提供瞄准和体感机关需要的陀螺仪输入。在手机安装 [MotionSourceiOS](https://github.com/shiftinv/MotionSourceiOS/releases/tag/v1.1.0)，让两台设备连接同一局域网，允许“本地网络”访问，选择 **Portrait**、保持加速度计开启，然后点 **Start Server**。在 Mac 游戏菜单栏选择 **Motion → Connect Phone…**，填写手机显示的 IP 和端口（默认 `26760`），连接后让手机静止一秒。菜单显示 **Phone motion connected** 即表示校准完成。游玩时保持 MotionSource 在前台、手机屏幕常亮。**Motion → Calibrate…** 用于测量漂移和重置朝向；**Disconnect Phone** 用于关闭体感。已保存的手机连接仅在 `phone` 模式下自动重连。方向设置和排查方法见[手机体感说明](docs/development.md#mac-phone-motion)。

存档位于 `~/Library/Application Support/org.nxnative.<标题号>/save`，日志位于 `~/Library/Logs/org.nxnative.<标题号>/log.txt`（标题号小写）。在 `save/` 旁放置 `env.txt` 可以调整设置。最低系统版本取决于包内着色器库：复用较新 SDK 生成的缓存时，可能高于 macOS 26。各游戏的 Mac 兼容性不同；目前马力欧的菜单和对话文字存在空白问题。

重新构建的 Mac App 会自动使用共享渲染器的状态和缓冲区缓存，以及不可变的 uniform 快照。这些优化保留游戏原有的分辨率、特效和运行时序。需要时可设置 `DM_LANG=zh-Hans` 使用简体中文、`DM_OPMODE=0` 使用掌机模式，修改后重启游戏。其他选项见[环境变量说明](docs/development.md#mac-environment-variables)。

旷野之息 1.9.0 的 Mac 构建支持 `DM_GAME_RES=1920x1080`，将场景、HUD 和输出一起提高到真正的 1080p；`DM_GAME_RES=1280x720` 则使用 720p。在用户 `env.txt` 中设置后重启生效。更高分辨率会增加 GPU 耗时，可按清晰度和帧率选择。

旷野之息 1.9.0 的 Mac 构建还可在 `env.txt` 中设置 `DM_FPS=90` 或 `DM_FPS=120`，重启后生效。这两个实验性模式按实际经过的时间调整游戏步长，同时保留游戏主动指定的时序。默认仍为 60；设置值是帧率上限，实际帧率取决于场景、GPU 和显示器，分辨率与特效保持不变。

旷野之息 1.9.0 的 Mac 构建可选用金手指：在用户 `env.txt` 中加入 `DM_CHEATS=health,stamina,durability,arrows` 后重启。按需保留用逗号分隔的选项，分别为红心不减、使用最大体力、将被检查装备的耐久补到 60000、箭矢不消耗。默认全部关闭；删除此行或设置 `DM_CHEATS=none`，重启即可关闭。耐久修改可能随游戏存档保留，使用前请备份存档。提供的 1.8.2 金手指文件不能直接加载。详见[金手指说明](docs/development.md#botw-mac-cheats)。

## 安装 IPA

使用 AltStore、Sideloadly 或 LiveContainer 等工具侧载。工具支持 **Increased Memory Limit** 时请开启，较大的游戏需要它。游戏过大时，使用 `--romfs separate` 重新构建，再执行脚本给出的文件复制命令（[快速重装](docs/development.md#quick-reinstalls)）。[操作、存档与设置](docs/playing.md)。

## 游戏

上面的游戏列表包含在 Mac 或 iPhone 上实测的游戏；[各游戏说明](dm/games/README.md#games)记录了测试平台、版本和已知问题。“60 fps with 1.2.0”表示该更新版从 Switch 的 30 fps 提升到 60 fps。

iPhone 需要 iOS / iPadOS 26 或更新版本，以及 iPhone 15 Pro（A17 Pro）或更新设备，或 M1 及更新 iPad，因为游戏使用 BC 压缩纹理。其他游戏仍可生成调查报告并尝试构建，但可能无法启动。

## 开发者

[原理与构建](docs/development.md) · [游戏说明](dm/games/README.md#games) · [移植与调试](docs/agents/README.md) · [前端接口](docs/frontends.md) · [贡献](CONTRIBUTING.md)

## 致谢与许可

本项目起源于 **[d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile)**（MIT）的 NSO 改写器、Horizon 宿主、Metal 上的 NVN 和 iOS 外壳，修复双向共享。感谢 **Ryujinx**（着色器翻译和系统服务参考）、**Atmosphère**（同步语义）、**yuzu**（Maxwell 指令与内核参考）、**LibHac** 与 **hactool**（读取游戏文件）、**SPIRV-Cross** 与 **glslang**（着色器）、**deko3d**（纹理布局）、**libvpx**、**stb_vorbis**、**Vulkan headers**、**NVIDIA FLIP**，以及构建工具 **Capstone**、**lz4**、**fontTools**、**XcodeGen**。第三方代码和许可证见 [dm/third_party](dm/third_party/README.md)。本项目采用 [MIT 许可证](LICENSE)。
