#!/bin/bash
# Builds the Release app and packs it into dist/Corkscrew-<version>.dmg, with an Applications link to
# drag it to. Ad hoc signed: until there's a Developer ID, macOS asks to "Open Anyway" once.
# The app in the DMG carries its engine pack (EnginePackPin.swift) in Contents/Resources/EnginePack,
# so setup downloads only Steam. The pack comes from dist/runtime-<release>/ when it's there, else
# from its release; either way it must match the pinned SHA-256. Its release has to be published
# (it holds the source code), which this checks, unless CORKSCREW_TRY_DMG=1 (to try a DMG out locally).
# For the in-app updater (AppUpdate.swift) it also writes dist/Corkscrew-<version>-app.zip, the app
# without the engine pack, and dist/update.json, which gives the zip's URL in the v<version> release
# and the pinned pack.
# Usage: make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PIN=Packages/GameCore/Sources/GameCore/Engines/EnginePackPin.swift
PACK_URL=$(sed -nE 's/.*URL\(string: "([^"]+)"\).*/\1/p' "$PIN")
PACK_SHA256=$(sed -nE 's/.*sha256: "([0-9a-f]+)".*/\1/p' "$PIN")
PACK_RELEASE=$(sed -nE 's/.*version: "([^"]+)".*/\1/p' "$PIN")
PACK_SIZE=$(sed -nE 's/.*size: ([0-9]+).*/\1/p' "$PIN")
PACK_NAME=$(basename "$PACK_URL")
if ! curl -sfIL -o /dev/null "$PACK_URL"; then
  echo "The engine pack isn't published yet: $PACK_URL" >&2
  echo "Publish it first (scripts/package-engine.sh prints the command)." >&2
  [[ -n ${CORKSCREW_TRY_DMG:-} ]] || exit 1
fi

PACK="dist/runtime-$PACK_RELEASE/$PACK_NAME"
if [[ ! -f $PACK ]]; then
  PACK="build/enginepack/$PACK_NAME"
  if [[ ! -f $PACK ]] || [[ $(shasum -a 256 "$PACK" | cut -d' ' -f1) != "$PACK_SHA256" ]]; then
    mkdir -p build/enginepack
    echo "Downloading $PACK_URL"
    curl -fL --retry 3 -o "$PACK.part" "$PACK_URL"
    mv "$PACK.part" "$PACK"
  fi
fi
[[ $(shasum -a 256 "$PACK" | cut -d' ' -f1) == "$PACK_SHA256" ]] \
  || { echo "$PACK doesn't match the SHA-256 in $PIN" >&2; exit 1; }

scripts/build-app.sh Release
APP=build/DerivedData/Build/Products/Release/Corkscrew.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")

mkdir -p dist
# The app alone: an update downloads about 7 MB, and the new app downloads the engine pack only when
# it pins a newer one.
ZIP="dist/Corkscrew-$VERSION-app.zip"
codesign --verify --deep --strict "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
# The full URL: GitHub sends releases/latest/download/update.json to a signed CDN URL, and a file name
# relative to that one doesn't resolve (0.9.0 got HTTP 618).
ZIP_URL="https://github.com/Prateek-Srivastav/corkscrew/releases/download/v$VERSION/$(basename "$ZIP")"
cat >dist/update.json <<EOF
{
  "version": "$VERSION",
  "app": {"name": "$ZIP_URL", "sha256": "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)", "size": $(stat -f %z "$ZIP")},
  "enginePack": {"version": "$PACK_RELEASE", "url": "$PACK_URL", "sha256": "$PACK_SHA256", "size": $PACK_SIZE}
}
EOF

DMG="dist/Corkscrew-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Corkscrew.app"
# Into the staged copy, so later Release builds of the app don't carry an old pack.
RESOURCES="$STAGE/Corkscrew.app/Contents/Resources/EnginePack"
mkdir -p "$RESOURCES"
cp "$PACK" "$RESOURCES/"
# The licenses and source list in the open too: Apple's license wants its notices with every copy of D3DMetal.
tar -xf "$PACK" -C "$RESOURCES" --strip-components 1 "${PACK_NAME%.tar.xz}/LICENSES" "${PACK_NAME%.tar.xz}/SOURCES.md"
codesign --force --sign - "$STAGE/Corkscrew.app"
codesign --verify --deep --strict "$STAGE/Corkscrew.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Corkscrew $VERSION" -srcfolder "$STAGE" -format ULFO -ov "$DMG"
(cd dist && shasum -a 256 "$(basename "$DMG")" >"$(basename "$DMG").sha256")
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
