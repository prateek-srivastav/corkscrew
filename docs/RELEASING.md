# Releasing

A release has two parts:

- **The engine pack** (`runtime-*` releases): the Wine runtime, D3DMetal, DXMT and DXVK, built on the maintainer's Mac, with the source of everything in it. It only changes when the runtime or components change.
- **The app** (`v*` releases): `Corkscrew-<version>.dmg`, built by GitHub Actions from a tag. Each app version points at one engine pack (`EnginePackPin.swift`), and the DMG's app carries that pack, so setup doesn't download it. Builds without it (from source) download it.

## A new engine pack

Needed when `scripts/build-runtime.sh`, `scripts/install-components.sh` or `scripts/runtime-pins.env` change.

The **Upstream releases** workflow runs `scripts/check-upstream.sh` every Monday. It opens an issue for each CrossOver, DXMT, DXVK, MoltenVK, Wine Mono or Game Porting Toolkit release newer than its pin, once per version. For the Game Porting Toolkit it reads Apple's public page, which names only the major version, so a minor release (for example 3.1) doesn't open an issue.

1. Commit the script changes. The packaging script refuses uncommitted changes in `scripts/` and `tools/`, so the published build scripts match the runtime.
2. Build the runtime and components:

   ```bash
   scripts/build-runtime.sh
   ```

   ```bash
   scripts/install-components.sh ~/Downloads/Game_Porting_Toolkit_3.0.dmg
   ```

   The pack includes D3DMetal from this image: `scripts/runtime-pins.env` pins its SHA-256 (`GPTK_DMG_SHA256`), and packaging refuses D3DMetal staged from any other image. Apple's license allows redistributing it only for non-commercial purposes, with Apple's license and acknowledgements, which the pack carries in `LICENSES/apple-game-porting-toolkit/`.

3. Run the smoke test. All backends should pass:

   ```bash
   scripts/smoke.sh
   ```

4. Pack it. The release name is the Wine version plus a revision; bump the revision for every new pack of the same Wine version:

   ```bash
   scripts/package-engine.sh 26.3.0-2
   ```

   This writes `dist/runtime-<release>/` and updates `Packages/GameCore/Sources/GameCore/Engines/EnginePackPin.swift`.

   Apps pinned to the new pack replace a runtime from an older pack when they open (when no bottle is running), with the pack's components. Runtimes added by hand or from `build/runtime` are never replaced.
5. Commit `EnginePackPin.swift`.
6. Publish the pack and its source. `package-engine.sh` prints the exact command; it's a pre-release, so the app release stays "Latest":

   ```bash
   gh release create runtime-26.3.0-2 --prerelease --title "Engine 26.3.0-2" --notes "…" dist/runtime-26.3.0-2/*.tar.* dist/runtime-26.3.0-2/SHA256SUMS
   ```

To check a pack before publishing it, serve `dist/runtime-<release>/` locally and install from there into a scratch folder:

```bash
python3 -m http.server 8765 --directory dist/runtime-26.3.0-2
```

```bash
Packages/GameCore/.build/debug/gamecore-cli runtime download --data /tmp/corkscrew-test --url http://127.0.0.1:8765/corkscrew-engine-26.3.0-2.tar.xz
```

The app takes the same override: `-EnginePackURL <url>`.

## A new app version

1. Set the version in `project.yml` (`CFBundleShortVersionString`, and bump `CFBundleVersion`). Commit and push.
2. Make sure the engine pack in `EnginePackPin.swift` is published; the build checks.
3. Tag and push the tag:

   ```bash
   git tag v0.3.0 && git push origin v0.3.0
   ```

4. The **Release** workflow downloads the pinned engine pack, puts it in the app, builds the DMG, the app-only zip and `update.json`, and creates a draft release with them. Read the notes, try the DMG, then publish the draft.

To build the DMG locally instead: `scripts/make-dmg.sh`. It takes the pack from `dist/runtime-<release>/` when it's there, and needs `CORKSCREW_TRY_DMG=1` while the pack isn't published yet.

`scripts/install.sh` (the `curl … | bash` install in the README, served from GitHub Pages as `https://prateek-srivastav.github.io/corkscrew/install.sh`) installs the release that `releases/latest` points at, so it picks up a new version once the draft is published. It expects the assets to keep their names, `Corkscrew-<version>.dmg` and `Corkscrew-<version>.dmg.sha256`, on a `v<version>` tag. To try a DMG with it before publishing, serve a folder laid out as `download/v<version>/<assets>` and run `CORKSCREW_RELEASES=http://127.0.0.1:8765 CORKSCREW_VERSION=<version> CORKSCREW_APP_DIR=/tmp/apps scripts/install.sh`.

The app looks for a new version each time it opens. It reads `update.json` from `releases/latest`, so it sees a release once the draft is published. When the version is newer, it shows an Update bar with the download size: the app-only zip (`Corkscrew-<version>-app.zip`, about 7 MB), plus the engine pack when the new version pins a newer one. **Update** downloads the zip, checks its SHA-256, puts the new app in place of the old one and restarts. The new app downloads its engine pack when it opens. `update.json` gives the zip's full URL in the `v<version>` release, so keep the tag and asset names. (A name relative to `update.json` doesn't work: GitHub sends it to a signed CDN URL.) Versions up to 0.8.1 have no updater: their users update with the install script. To try an update before publishing, serve a folder with the zip and `update.json`, change `name` in `update.json` to the zip's file name, and open an older build with `-UpdateURL http://127.0.0.1:8765/update.json`. Debug builds look for updates only with `-UpdateURL`.

The app is ad hoc signed, so users confirm it once with **Open Anyway**. Signing with a Developer ID and notarizing would remove that step; it needs an Apple Developer Program membership.

## Website

The **Pages** workflow publishes `site/` (the landing page) and `scripts/install.sh` to https://prateek-srivastav.github.io/corkscrew/ when either changes on main. The repository's Pages source must be **GitHub Actions** (Settings → Pages). The page shows one screenshot, `site/img/library.webp`, a WebP copy of `docs/screenshots/library.png`. WebP keeps the clear rounded corners of the window; JPEG fills them with white. After changing that screenshot, regenerate it with `cwebp -q 85 -m 6 docs/screenshots/library.png -o site/img/library.webp` (`brew install webp`). `site/img/library.jpg` is the link preview (`og:image`), which must be JPEG, so its corners are filled with the page color: `python3 -c 'from PIL import Image; s = Image.open("docs/screenshots/library.png").convert("RGBA"); b = Image.new("RGBA", s.size, "#0d0609"); b.alpha_composite(s); b.convert("RGB").save("site/img/library.jpg", quality=80)'` (needs Pillow). To preview: `python3 -m http.server -d site`.
