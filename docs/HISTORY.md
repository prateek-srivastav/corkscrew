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
  - A Steam game's launch follows the game's own processes rather than `steam.exe`.
  - When the game quits, the app closes what it started: Steam and the launcher.
  - It closes the Rockstar launcher with a hard kill, because a normal quit signs you out and breaks automatic sign-in.
