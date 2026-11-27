# How Corkscrew was built

## M0: the runtime
- Scripts that build Wine's x86_64 dependencies (FreeType, GnuTLS, Nettle, SDL2) and winecx 26.3, with every download pinned by version and SHA-256 (`scripts/runtime-pins.env`).
  - Libraries are relocatable through `@rpath`.
  - The loader is marked as a game for macOS Game Mode.
- Installing DXMT, DXVK-macOS and D3DMetal (taken from Apple's Game Porting Toolkit disk image) as switchable backends.
- DX11/DX12 clear-screen test programs and a smoke test across all backends.

## M1: the GameCore library and CLI
- PE inspection (imports, delay-imports, runtime-loaded D3D DLLs, game engine, anti-cheat markers, icons) and automatic backend choice.
- Bottles: create, clone, import, reset, and update automatically when the runtime changes.
- Isolated bottles:
  - A sandbox profile, verified with canary files that a standard bottle can read and an isolated one can't.
  - Program output reaches its log through a pipe, because the sandbox blocked files outside each launch's own folder.
- Runtime store (SHA-256-checked archives, or APFS clones of a local build), and a GPTK importer that mounts Apple's disk images and stages D3DMetal.
- Per-game Retina mode, handling the fact that Wine fixes display sizes for a whole bottle session.
- Steam support:
  - A wrapper for Steam's built-in browser (`--disable-gpu --single-process`). Without it Steam's window is black and its network service fails.
  - Library entries for each installed game, with tested settings per game.
- A performance overlay that sits over fullscreen games, is click-through, and quits with the game.

## M2: the app
- SwiftUI app:
  - Library grid with icons, drag-and-drop and hover Play, plus Bottles, Setup and per-game settings.
  - A log viewer per launch that follows a running game.
  - `corkscrew://launch/<id>` and `corkscrew://stop/<id>` links.
- Zero setup in a dev checkout: the app finds the built runtime and components, and creates a "Games" bottle.
- Steam games that are uninstalled keep their library entry as "Not Downloaded"; Play opens their Steam store page.
- Standard bottles keep their Windows folders inside them. Wine links Documents, Downloads, Music, Pictures and Videos to the Mac's, so games saved among the user's files (`~/Documents/Rockstar Games`), and macOS asked for access to Documents after every update of a build signed without a fixed certificate.
  - A new standard bottle gets folders of its own. Wine links an empty one again when it updates a bottle, so the links are cut again before every launch, as in isolated bottles.
  - A bottle made before asks once, when nothing runs in it. On **Look for Files** it lists what in the Mac's Documents changed since the bottle was made, and ticks what changed at least 90% of the time while the bottle ran (from its launch logs; Rockstar's launcher writes its cache after a launch's log ends). The ticked items are copied in as APFS clones; the originals stay.
  - Only Documents is looked in, where Windows games keep saves and settings, and only after the click. macOS asks to let Corkscrew into each of Documents, Downloads, Music ("Apple Music"), Pictures and Movies: looking in all five at startup brought five prompts before the sheet said why. What games put in the other folders (screenshots, clips) stays in the Mac's.
  - A folder macOS didn't let Corkscrew read keeps its link and nothing is copied: read as empty, its link would have been swapped for an empty folder, hiding the saves from the game.
  - All or nothing: the copies go into a folder beside each link, and the links are replaced only when every copy is made. A file that can't be copied (one iCloud can't download) leaves the bottle as it was.
  - The bottle's page switches it either way. Linking again merges the bottle's folders into the Mac's, folder into folder, so a Mac folder of the same name (`My Games`) keeps other games' saves. Of two files with the same name, the newer stays and the older goes to the Trash.
- The app is filed under Utilities, not Games: the games run from the loader, which is the one marked as a game for Game Mode.

## Red Dead Redemption 2
Getting RDR2 to run took several fixes, all of them applied automatically before launch:
- **Rockstar Games Launcher wouldn't start.** It draws with Direct2D, which needs Wine's own Direct3D. Games started from Steam inherit D3DMetal.
  - Fix: the launcher and its Social Club helper get Wine's Direct3D DLLs, rendering through OpenGL, while the game keeps D3DMetal.
  - D3DMetal's GPU vendor libraries are turned off for the launcher; they crashed it once signed in.
- **Social Club pages were white** (sign-in, prompts, the hidden launcher window).
  - Cause: Social Club is Chromium, whose GPU process draws into another process's windows, and Wine's macOS driver drops that drawing.
  - Fix: a runtime patch starts Social Club with `--in-process-gpu`, so it draws in its own process. The app warns when the runtime was built without the patch.
- **DX12 on D3DMetal.** The game's settings are set to DX12 before each launch. Vulkan would go through MoltenVK instead.
- **Tested graphics settings from the start.** Before the game's first launch, the app writes the settings tested here: DirectX 12, Fullscreen at the Mac's desktop size, Ultra textures, High shadows, reflections and lighting, Medium for most of the rest, and DLSS, which runs as MetalFX. After that they're the player's own to change in game. They're in `Packages/GameCore/Sources/GameCore/Stores/RDR2Settings.swift`.
- **Small window in the middle of the screen** (if you switch to Windowed Borderless).
  - In Windowed Borderless, RDR2 sizes its window from its resolution setting, and its defaults pick a size smaller than the desktop.
  - Fix: the app sets that resolution to the desktop's size.
- **Launch and quit like a native game.**
  - A Steam game's launch follows what Steam itself logs of the game (`logs/gameprocess_log.txt`), not the bottle's processes:
    - Steam logs every program it follows for the game: the one it started (`PlayRDR2.exe`), and the ones that program starts (the Rockstar launcher, `RDR2.exe`, its crash handler).
    - Steam logs when it stops following each one, and when the game has ended. That includes a game that quits inside Rockstar's launcher before `RDR2.exe` ever runs.
    - The launch wakes when Steam writes to that log, or a program exits. It doesn't look every few seconds. For a minute after each thing Steam logs, it also looks for the game's windows, to bring them forward.
  - Next to Play, the status line shows the launch as it happens: "Waiting for Steam…", then "Starting" with the newest program's name, from the program itself, as Task Manager shows it ("Rockstar Games Launcher").
  - After Steam ends the game, what started with it closes by itself ("Closing Rockstar Games Launcher…"), and the launch follows those programs until they exit, for up to 30 seconds. Corkscrew ends none of them. If Steam never logs the end, the player ends the launch with Force Stop, which stops the bottle, also when Steam was open before. If Steam starts nothing for the game in 10 minutes, and none of its installers run, the launch ends by itself.
  - `launch-tracking.log` next to the launch's log records each step and which programs ran.
  - **A Rockstar launcher that can't start the game.** Now and then its background service (RockstarService) doesn't answer the launcher's handshake within half a second; it usually takes about 0.35. The launcher then talks to it in an older protocol it ignores, restarts it every 30 seconds, and never starts the game: 89 tries in 25 minutes once, while the next launch worked first time. It wasn't memory: the launch that worked had more of the Mac swapped out.
    - The launch reads the launcher's `launcher.log` while it starts. On "Handshake with service timed out", the status line says "Rockstar Games Launcher is stuck. Force Stop, then Play again." with a warning sign, and when Corkscrew isn't in front, a notification says so; a click opens the game's page. Corkscrew stops nothing itself. If the game starts after all, the status line follows it again. The log is read as it grows, not whole on every look.
  - Then Steam quits as its own Exit does ("Quitting Steam…"), when the game's launch started it and no other Steam game runs. A Steam the player opened stays open.
    - Only Steam is asked to quit. What the game left running stays, and Wine's own services end once nothing runs in the bottle.
    - For a while Steam stayed open after the game, so the next launch skipped Steam's start: 1 second to the Rockstar launcher instead of 25. Idle, it held about 1.4 GB (its Chromium web helper alone 1 GB, most of it compressed by macOS) and a few percent of one core. Steam can't run without that web helper, so a warm Steam can't be made lighter; Steam quits again instead.
- **Quitting Corkscrew quits what it runs.**
  - Steam quits as its own Exit does, so it saves its state. Then what's left in each bottle stops.
  - While a game runs or starts, Corkscrew doesn't quit. It asks instead: Show opens the game's page, Force Quit stops the game and quits, and ✕ stays.
  - Steam used to quit 30 seconds after its window closed. Corkscrew checked its windows every 10 seconds for that, and the check is gone.
