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

To build the DMG locally instead: `scripts/make-dmg.sh`. It takes the pack from `dist/runtime-<release>/` when it's there, and needs `CORKSCREW_TRY_DMG=1` while the pack isn't published yet. It marks its app as a release build (`CorkscrewDistribution` = `release` in Info.plist); reports from any other build say "built from source".

`scripts/install.sh` (the `curl … | bash` install in the README, served from GitHub Pages as `https://prateek-srivastav.github.io/corkscrew/install.sh`) installs the release that `releases/latest` points at, so it picks up a new version once the draft is published. It expects the assets to keep their names, `Corkscrew-<version>.dmg` and `Corkscrew-<version>.dmg.sha256`, on a `v<version>` tag. To try a DMG with it before publishing, serve a folder laid out as `download/v<version>/<assets>` and run `CORKSCREW_RELEASES=http://127.0.0.1:8765 CORKSCREW_VERSION=<version> CORKSCREW_APP_DIR=/tmp/apps scripts/install.sh`.

The app looks for a new version each time it opens. It reads `update.json` from `releases/latest`, so it sees a release once the draft is published. When the version is newer, it shows an Update bar with the download size: the app-only zip (`Corkscrew-<version>-app.zip`, about 7 MB), plus the engine pack when the new version pins a newer one. **Update** downloads the zip, checks its SHA-256, puts the new app in place of the old one and restarts. The new app downloads its engine pack when it opens. `update.json` gives the zip's full URL in the `v<version>` release, so keep the tag and asset names. (A name relative to `update.json` doesn't work: GitHub sends it to a signed CDN URL.) Versions up to 0.8.1 have no updater: their users update with the install script. To try an update before publishing, serve a folder with the zip and `update.json`, change `name` in `update.json` to the zip's file name, and open an older build with `-UpdateURL http://127.0.0.1:8765/update.json`. Debug builds look for updates only with `-UpdateURL`.

The app follows the issue of each report it sent, on its **Reports** page in the sidebar (Help → Your Reports; users can add an issue by number there too, but only one with the `crash-report` label, which the relay puts on each report it opens: don't remove it). It reads GitHub at launch and every 30 minutes, with no token, and shows a macOS notification and a dot when something changes. What the page shows comes from the issue:

| On the issue | In the app |
| --- | --- |
| open, no status label | Received |
| label `investigating` | Looking into it |
| label `question` | Needs details from you (with a link to the issue) |
| label `upstream` (open or closed) | Not a Corkscrew problem |
| closed | Closed |
| entry in `docs/fixes.json` | Fixed in this version / Fixed in 1.0.3 (Update) / Fix coming in 1.0.3 |

A **note** is a comment from the owner or a collaborator that starts with `Note:`. The app shows the rest of the comment (Markdown links work) under the report and in the notification. Use one for steps the user can take, for example when the cause is not Corkscrew's. Other comments, and comments from anyone else, don't show. Issues are public, so a note is public too.

When a version fixes an issue that a sent report opened, add the issue and that version to `docs/fixes.json` on main: `[{"issue": 51, "version": "1.0.2", "cause": "…", "change": "…"}]`. `cause` (what was wrong) and `change` (what changed) are one short line each, shown in the fix popup. The app that sent the report shows "Fix coming in 1.0.2" until the release is published, then a popup once: "fixed in this version", or "Update to get it". For a fix that many may have hit, add `"everyone": true` and a `"title"` (one short line): every Mac whose version has the fix then shows "A reported problem is fixed" once, after an update too. Macs where Corkscrew wasn't set up yet count it as told. It isn't offered as an update: it shows only in a version that has the fix. Older versions read this file too: add keys, don't rename or remove them, and don't move the file. To try it, open a build with `-ReportFixesURL <url>` and `-ReportIssuesAPI <url>` (a folder that answers like `https://api.github.com/repos/<owner>/<repo>/`), and a `SentReports` default such as `{51 = "Game crashed";}`, which the app moves to its Reports page. Debug builds read the list too, as builds from source are Debug builds.

## Signing

Releases are signed with Corkscrew's own self-signed certificate. So every version has the same designated requirement (`identifier "io.github.prateek-srivastav.Corkscrew" and certificate leaf = H"<SHA-1>"`), and macOS keeps the permissions users gave Corkscrew (Documents, notifications and so on) after an update. An ad hoc signature changes with each build, so macOS sees each update as a new app and asks again.

Make the certificate once, on your Mac:

```bash
scripts/make-signing-cert.sh
```

It writes `~/.corkscrew-signing/corkscrew-signing.p12` and its password file, and prints the commands that put them into the repository's Actions secrets (`CORKSCREW_SIGNING_P12`, the `.p12` in base64, and `CORKSCREW_SIGNING_PASSWORD`) and the certificate's SHA-1 into the Actions variable `CORKSCREW_SIGNING_SHA1`. Keep a backup of both files outside the repository, and never make a new certificate: a new one makes every user give the permissions again. Never commit them.

The **Release** workflow passes these to `scripts/make-dmg.sh`, which imports the certificate into a keychain of its own (deleted at the end) and signs the app and `perf-overlay` with it. Every run in this repository uses the same secret, whoever pushed the tag, so every release has the same fingerprint; the build stops if the certificate's SHA-1 isn't `CORKSCREW_SIGNING_SHA1`, or if either is missing. Forks and pull requests from forks get no secrets: their builds are ad hoc signed, and they can't sign as Corkscrew. Without the variables, `make-dmg.sh` signs ad hoc (builds from source, local tries). To check a build: `codesign -d -r- Corkscrew.app`.

The in-app updater keeps the signature as it is: it unpacks the zip with `ditto`, removes the quarantine attribute and runs `codesign --verify --deep --strict`, which a self-signed signature passes. Users who update from an ad hoc version (1.0.2 and older) get each permission prompt once more; after that, updates keep them.

The certificate isn't a Developer ID and the app isn't notarized, so Gatekeeper still rejects a downloaded DMG: users confirm it once with **Open Anyway**. The install script and the updater remove the quarantine attribute, so they don't ask. A Developer ID and notarization would remove that step; they need an Apple Developer Program membership, and would change the designated requirement once more.

## Website

The **Pages** workflow publishes `site/` (the landing page) and `scripts/install.sh` to https://prateek-srivastav.github.io/corkscrew/ when either changes on main. The repository's Pages source must be **GitHub Actions** (Settings → Pages). The page shows the intro video, `site/video/intro.mp4`, with `site/img/intro-poster.jpg` as its poster. It plays muted while it is in view. The README links `docs/intro-poster.jpg` (the same frame with a play button) to the video on the site. The video's sources (recordings, the editor script, the 4K 60 fps master) aren't in the repository. Keep the web copy H.264, so every browser plays it, and under 10 MB, GitHub's limit for a video in a README: `ffmpeg -i master.mp4 -vf scale=1920:-2:flags=lanczos -c:v libx264 -preset veryslow -crf 25.6 -profile:v high -pix_fmt yuv420p -c:a aac -b:a 128k -movflags +faststart site/video/intro.mp4`. `site/img/library.jpg` is the link preview (`og:image`), which must be JPEG, so its corners are filled with the page color: `python3 -c 'from PIL import Image; s = Image.open("docs/screenshots/library.png").convert("RGBA"); b = Image.new("RGBA", s.size, "#0d0609"); b.alpha_composite(s); b.convert("RGB").save("site/img/library.jpg", quality=80)'` (needs Pillow). To preview: `python3 -m http.server -d site`.
