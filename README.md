
<img src="docs/icon.png" width="128" height="128" alt="Corkscrew icon">

# Corkscrew

[![CI](https://github.com/Prateek-Srivastav/corkscrew/actions/workflows/ci.yml/badge.svg)](https://github.com/Prateek-Srivastav/corkscrew/actions/workflows/ci.yml) [![License: GPL v3](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

A native macOS app (Swift 6, SwiftUI) that runs Windows games and launchers on Apple Silicon Macs. It builds its own Wine runtime, picks a graphics translation layer per game, keeps games in separate Wine prefixes ("bottles"), and can run untrusted programs inside a macOS sandbox.

It's developed and tested on a 14" MacBook Pro (M4, 16 GB, macOS 27). It runs games through their stores and launchers, and any Windows program you add. Corkscrew itself doesn't bypass DRM or copy protection. Contributions are welcome (see [Contributing](#contributing)).

| Library | Steam |
|---|---|
| <img src="docs/screenshots/library.png" alt="The Library: every game from every bottle, with the last-played ones in a carousel"> | <img src="docs/screenshots/steam.png" alt="The Steam page: the signed-in account's Steam library"> |
| **Game page** | **Online Programs** |
| <img src="docs/screenshots/game.png" alt="A game page with its art, Open in Steam, and details from the Steam store"> | <img src="docs/screenshots/online.png" alt="Online Programs, a protected bottle with internet on and a Steam of its own"> |

## Install

You need an Apple Silicon Mac with macOS 26 or 27, and about 3.5 GB of free space plus your games.

1. Install it from Terminal:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/Prateek-Srivastav/corkscrew/main/scripts/install.sh | bash
   ```

   The [script](scripts/install.sh) downloads the latest DMG (about 320 MB), checks its SHA-256, copies Corkscrew to Applications (replacing an older one) and opens it. Run it again to update.

   Or download `Corkscrew-<version>.dmg` from the [latest release](https://github.com/Prateek-Srivastav/corkscrew/releases/latest), open it, and drag Corkscrew to Applications.
2. If you used the DMG: Corkscrew isn't signed with an Apple Developer ID yet, so macOS blocks it the first time. Click **Done**, then **Open Anyway** in **System Settings → Privacy & Security**. You only do this once. The Terminal install skips this step, because macOS only checks apps that a browser downloaded.
3. Click **Set Up Corkscrew**. It installs Rosetta if needed, unpacks the Wine runtime and graphics translators that come inside the app (checked against a built-in SHA-256), creates a Steam bottle with Steam, and makes two protected bottles for other programs: Offline Programs (no internet) and Online Programs.
4. Open Steam from the Library, sign in, and install your games.

Apple plans to limit Rosetta after macOS 27, and the runtime needs it; an ARM64 runtime is on the [roadmap](#roadmap). To build from source, see [Building](#building).

## What works

| Area | Status |
|---|---|
| Wine runtime | CodeWeavers' open-source Wine (winecx 26.3, Wine 11 base), built for x86_64, run under Rosetta 2 in WoW64 mode |
| Graphics | D3DMetal (Game Porting Toolkit 3.0), DXMT, DXVK with MoltenVK, and WineD3D, switchable per game; MetalFX upscaling through games' DLSS option |
| Steam | Installs, signs in, downloads and launches games, which show up in the Library by themselves; any bottle can have its own Steam |
| Rockstar Games Launcher | Starts, signs in (Social Club), and launches games |
| Isolated bottles | Programs run in a macOS sandbox with no access to your files; internet off unless you turn it on; DX11 and DX12 render inside it |
| App | Library with a tab per bottle, per-game settings, logs, Retina mode, Metal HUD and a performance overlay, Finder "Open With" for `.exe`/`.msi` |
| Game controllers | Xbox controller works in every tested game (not tried yet in Last Pirates Die Together), through Wine's SDL2 support |
| Game Mode | Turns on for fullscreen games in standard bottles |

### Games tested

| Game | Setup | Result |
|---|---|---|
| **Red Dead Redemption 2** | Steam → Rockstar Games Launcher, DX12 on D3DMetal | Plays at about 50 FPS (25 in Retina mode) with the tested settings: Ultra textures, High shadows and lighting, DLSS as MetalFX. |
| **Black Myth: Wukong Benchmark Tool** | Steam, DX12 + MetalFX on D3DMetal | 50 FPS average at 1512×982 (Medium, MetalFX 59%), or 33 FPS at Retina 3024×1964. |
| **God of War (2018)** | Isolated bottle, internet off, DX11 on D3DMetal with a depth-test fix | Plays with the tested settings (Ultra preset, HDR off, no film grain), with no white specks on the characters ([#14](https://github.com/Prateek-Srivastav/corkscrew/issues/14)). |
| **Last Pirates Die Together** | Isolated bottle, internet on, with its own Steam; DX11 on D3DMetal | Plays; online co-op works. |
| **Emily is Away** | 32-bit, DX11 on DXVK | Runs |

## How it works

```
Corkscrew.app (SwiftUI) · gamecore-cli
  └─ GameCore: Inspect (PE parser) · Graphics (backend choice) · Engines · Bottles
               Isolation (sandbox) · Stores (Steam, Rockstar) · Launch · Performance
       └─ winecx 26.3 (x86_64, Rosetta 2)
            └─ D3DMetal · DXMT · DXVK + MoltenVK · WineD3D → Metal
```

- **Graphics per launch.** Backend DLLs live outside Wine's own folder; each launch points `WINEDLLPATH` at the chosen one. 64-bit DX12/11 games get D3DMetal, other DX11/10 games DXMT. God of War gets D3DMetal (or DXMT) behind a small d3d11.dll (`tools/depth-equal-fix`) that fixes its depth test; the launch puts it next to the game.
- **Tuned for speed.** msync instead of wineserver waits, no Wine debug output, Game Mode, Steam's overlay off unless a game needs it, background shader compiles. `scripts/bench.sh` measures the overhead.
- **Bottles stay current.** A bottle is updated (`wineboot --update`) when the runtime changes.
- **Isolated bottles** run everything under a generated Seatbelt profile:
  - nothing outside the bottle is writable, and your home folder and other disks can't be read;
  - programs start only from the runtime, never through LaunchServices or launchd;
  - AppleEvents, the keychain, the clipboard and (by default) the network are blocked;
  - drive links out of the bottle are removed, and "Reset to Clean" restores a snapshot;
  - the Mac's root certificates are copied into the bottle, so HTTPS works without keychain access.

The development history, including the fixes RDR2 needed, is in [docs/HISTORY.md](docs/HISTORY.md).

## Building

You need an Apple Silicon Mac with macOS 26 or later, about 8 GB of free space, Rosetta 2 (`softwareupdate --install-rosetta --agree-to-license`), Xcode 26 or later (opened once), and [Homebrew](https://brew.sh). For DX12 games, also download **Game Porting Toolkit 3.0** from [Apple](https://developer.apple.com/games/game-porting-toolkit/).

```bash
git clone https://github.com/Prateek-Srivastav/corkscrew.git
```

Then, from the `corkscrew` folder, run these in order. The runtime build is the long step; if it stops, run it again and it continues.

```bash
scripts/bootstrap.sh
```

```bash
scripts/build-deps.sh
```

```bash
scripts/build-runtime.sh
```

```bash
scripts/install-components.sh ~/Downloads/Game_Porting_Toolkit_3.0.dmg
```

```bash
scripts/build-app.sh Debug
```

```bash
open build/DerivedData/Build/Products/Debug/Corkscrew.app
```

Open it from there the first time: it finds the runtime and components in `build/` and sets itself up. Every download is checked against the SHA-256 in `scripts/runtime-pins.env`.

**After `git pull`**, run `scripts/build-app.sh Debug` again. If `scripts/build-runtime.sh` or `scripts/runtime-pins.env` changed, delete `build/src/crossover-*`, rebuild the runtime, and run `scripts/install-components.sh` again.

**Tests:** `scripts/test.sh` (no runtime needed). For the graphics smoke test, run `scripts/make-fixtures.sh` then `scripts/smoke.sh`; `scripts/bench.sh` times Win32 calls and D3D11 draws per backend.

## Using it

- **Steam games** appear in the Library once installed. Tested games are listed under **Not Downloaded** from the start; their button opens them in Steam.
- **Other programs:** drag in an `.exe` or `.msi`, use Finder's "Open With", or **Run Program…** in a bottle. Choose **Run Once** for installers and **Add to Library** for games.
- **Per-game settings:** graphics backend, MetalFX, Retina mode, Metal HUD, performance overlay, Steam overlay, launch arguments and logs.
- **Untrusted programs:** create an **Isolated** bottle under Bottles → New Bottle. Turn on **Install Steam** if a game needs Steam; use a second Steam account there, because programs in the bottle can read its sign-in.
- **Data** lives in `~/Library/{Application Support,Logs,Caches}/Corkscrew`; pass `-DataRoot <folder>` to keep it in one folder.
- **Uninstall:** **Settings → Clean Up and Uninstall** stops every bottle, deletes the bottles with the games in them, Wine, the library, logs, caches and settings, then deletes the app.
- **CLI** (`swift build` in `Packages/GameCore`, run from the repository root): `gamecore-cli bottle create <name> [--isolated]`, `inspect <exe>`, and `run --bottle <name> [--backend d3dmetal] [--metalfx] [--hud] [--retina] [--verbose] [--env KEY=VALUE] <exe>`.

If something doesn't work, check [Known issues](#known-issues), then the game's log under **Logs** in its panel.

## Known issues

- **Isolated bottles use `sandbox-exec`**, which Apple has deprecated. It works on macOS 26 and 27, and the tests check the sandbox, but a future macOS could remove it. ([#6](https://github.com/Prateek-Srivastav/corkscrew/issues/6))
- **RDR2 crashes after changing graphics settings in game** ("No DirectX 12 adapter or runtime found"). Change settings, then quit and relaunch. ([#7](https://github.com/Prateek-Srivastav/corkscrew/issues/7))
- **The Rockstar launcher sometimes can't reach its library service.** Close it and play again. ([#8](https://github.com/Prateek-Srivastav/corkscrew/issues/8))
- **Networks that intercept TLS** break Steam downloads and put the Rockstar launcher offline. ([#9](https://github.com/Prateek-Srivastav/corkscrew/issues/9))
- **FSR 3 Frame Generation crashes DX12 games on D3DMetal.** Keep it off; DLSS (MetalFX) works. ([#10](https://github.com/Prateek-Srivastav/corkscrew/issues/10))
- **GPTK 4.0 beta 2 draws Wukong's textures as blocks** (an Apple bug), so stable 3.0 is the default. ([#11](https://github.com/Prateek-Srivastav/corkscrew/issues/11))
- **Steam's UI looks half-size in Retina mode**, because Windows DPI stays at 96. ([#12](https://github.com/Prateek-Srivastav/corkscrew/issues/12))
- **D3DMetal's shader cache** is shared by every bottle and GPTK version. ([#13](https://github.com/Prateek-Srivastav/corkscrew/issues/13))

## Roadmap

- **M3:** game profiles. **Isolation:** a blocked-actions panel and a network-block check.
- **M4:** shortcuts and controller settings. **M5:** Epic Games and Battle.net launchers.
- **M6:** an ARM64 Wine with FEX for x86 emulation, before Rosetta 2 is retired.
- **Distribution:** Developer ID signing, notarization, and automatic updates.

## Contributing

Bug fixes, game reports and new launcher support are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first, report games with the **Game report** issue form, ask in [Discussions](https://github.com/Prateek-Srivastav/corkscrew/discussions), report security problems as in [SECURITY.md](SECURITY.md), and follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

Corkscrew is free software: you can redistribute it and modify it under the terms of the [GNU General Public License](LICENSE), version 3 or (at your option) any later version. It comes with no warranty.

## Credits and licenses

This repository only contains Corkscrew's own code. The build scripts download each third-party component at build time, check it against `scripts/runtime-pins.env`, and keep it under `build/` (not in git). The DMG's app carries them as an **engine pack** (`Contents/Resources/EnginePack`) with their licenses; `scripts/package-engine.sh` makes it, and each pack is published as a `runtime-*` release with the source of everything in it.

| Component | Used for | License |
|---|---|---|
| [Wine](https://www.winehq.org), CodeWeavers' source (winecx 26.3.0) | Windows compatibility layer | LGPL 2.1 or later |
| [DXMT](https://github.com/3Shain/dxmt) 0.80 | Direct3D 10/11 → Metal | MIT |
| [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) 1.10.3 | Direct3D 9/10/11 → Vulkan | zlib/libpng |
| [MoltenVK](https://github.com/KhronosGroup/MoltenVK) 1.4.2 | Vulkan → Metal | Apache 2.0 |
| [Wine Mono](https://gitlab.winehq.org/mono/wine-mono) 10.4.1 | .NET in bottles | MIT, some parts under other open-source licenses |
| [FreeType](https://freetype.org) 2.13.3 | Fonts | FreeType License or GPL 2 |
| [GnuTLS](https://gnutls.org) 3.8.13 | TLS | LGPL 2.1 or later |
| [Nettle](https://www.lysator.liu.se/~nisse/nettle/) 3.10 and GMP | Cryptography for GnuTLS | LGPL 3 or GPL 2 |
| [SDL2](https://libsdl.org) 2.32.10 | Game controllers | zlib |
| [Swift Argument Parser](https://github.com/apple/swift-argument-parser) | `gamecore-cli` | Apache 2.0 |
| D3DMetal, from Apple's [Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/) 3.0 | Direct3D 11/12 → Metal | Apple's license (`Apple-License.rtf`, `Apple-Acknowledgements.rtf`). Not open source and not covered by Corkscrew's GPL. Its `redist` components may be redistributed only for non-commercial purposes, with Apple's notices: the free engine pack includes them, and anything that sells Corkscrew must leave them out. |

**Our changes to Wine** are patches applied by `scripts/build-runtime.sh`: the loader's Info.plist (bundle identifier, Game Mode keys); starting programs from an app bundle so Game Mode turns on; an opt-out of the loader's re-exec link for sandboxed bottles; and `--in-process-gpu` for Rockstar's Social Club.

Steam, Rockstar Games, Red Dead Redemption, Black Myth: Wukong, God of War, DirectX, DLSS, FSR, Metal and other names are trademarks of their owners. Corkscrew isn't affiliated with or endorsed by any of them.
