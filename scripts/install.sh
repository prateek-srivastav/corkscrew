#!/bin/bash
# Installs the latest Corkscrew release into /Applications (or ~/Applications when /Applications isn't
# writable), or replaces the one that's there. curl doesn't quarantine what it downloads, so the app
# opens without the "Open Anyway" step that an ad hoc signed app needs after a browser download.
# Usage: curl -fsSL https://raw.githubusercontent.com/Prateek-Srivastav/corkscrew/main/scripts/install.sh | bash
# Environment: CORKSCREW_VERSION=0.5.0 to install that version instead of the latest,
# CORKSCREW_APP_DIR=<folder> to install somewhere else, CORKSCREW_NO_OPEN=1 to not open the app after.
# CORKSCREW_RELEASES=<url> replaces https://github.com/<repo>/releases (for testing; needs CORKSCREW_VERSION).
set -euo pipefail

# Everything runs from main, called on the last line, so a download cut short runs nothing.
main() {
  local releases=${CORKSCREW_RELEASES:-https://github.com/Prateek-Srivastav/corkscrew/releases}

  [[ $(uname -s) == Darwin ]] || fail "Corkscrew runs on macOS only."
  # hw.optional.arm64 is 1 on Apple Silicon even in a Terminal running under Rosetta.
  [[ $(sysctl -n hw.optional.arm64 2>/dev/null) == 1 ]] || fail "Corkscrew needs an Apple Silicon Mac."
  local macos
  macos=$(sw_vers -productVersion)
  (( ${macos%%.*} >= 26 )) || fail "Corkscrew needs macOS 26 or later; this Mac has macOS $macos."

  local version=${CORKSCREW_VERSION:-}
  if [[ -z $version ]]; then
    # releases/latest redirects to the newest published release that isn't a pre-release
    # (engine packs are pre-releases). No API call, so no rate limit.
    local tag
    tag=$(curl -fsSIL -o /dev/null -w '%{url_effective}' "$releases/latest") \
      || fail "Couldn't reach $releases/latest. Check your internet connection."
    tag=${tag##*/}
    [[ $tag == v* ]] || fail "Couldn't find the latest release at $releases/latest."
    version=${tag#v}
  fi
  version=${version#v}
  local name="Corkscrew-$version.dmg"

  if pgrep -xq Corkscrew; then
    fail "Corkscrew is open. Quit it (and stop any games), then run this again."
  fi

  local dir=${CORKSCREW_APP_DIR:-/Applications}
  if [[ -z ${CORKSCREW_APP_DIR:-} && ! -w /Applications ]]; then dir=$HOME/Applications; fi
  mkdir -p "$dir"
  [[ -w $dir ]] || fail "Can't write to $dir."

  TMP=$(mktemp -d -t corkscrew-install)
  trap cleanup EXIT

  say "Downloading Corkscrew $version"
  curl -fL --retry 3 --progress-bar -o "$TMP/$name" "$releases/download/v$version/$name" \
    || fail "Couldn't download $name from $releases/download/v$version/."
  curl -fsSL --retry 3 -o "$TMP/$name.sha256" "$releases/download/v$version/$name.sha256" \
    || fail "Couldn't download $name.sha256."
  say "Checking the SHA-256"
  (cd "$TMP" && shasum -a 256 -c --status "$name.sha256") \
    || fail "$name doesn't match its SHA-256. Nothing was installed."

  say "Installing into $dir"
  MOUNT="$TMP/mount"
  mkdir "$MOUNT"
  hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$TMP/$name" \
    || fail "Couldn't open $name."
  [[ -d $MOUNT/Corkscrew.app ]] || fail "$name has no Corkscrew.app."
  # Copy next to the old app first, so a failed copy leaves the old one in place.
  NEW="$dir/.Corkscrew.app.new"
  rm -rf "$NEW"
  ditto "$MOUNT/Corkscrew.app" "$NEW"
  hdiutil detach -quiet "$MOUNT" && MOUNT=
  # Only Corkscrew's own files: proxies and security tools can still add the flag to a download.
  xattr -dr com.apple.quarantine "$NEW" 2>/dev/null || true
  codesign --verify --deep --strict "$NEW" 2>/dev/null \
    || fail "The app in $name doesn't pass codesign --verify. Nothing was installed."
  rm -rf "$dir/Corkscrew.app"
  mv "$NEW" "$dir/Corkscrew.app" && NEW=

  say "Installed Corkscrew $version in $dir/Corkscrew.app"
  if [[ -z ${CORKSCREW_NO_OPEN:-} ]]; then
    open "$dir/Corkscrew.app"
  fi
}

TMP=
MOUNT=
NEW=
cleanup() {
  [[ -n $MOUNT ]] && hdiutil detach -quiet -force "$MOUNT" 2>/dev/null
  [[ -n $NEW ]] && rm -rf "$NEW"
  [[ -n $TMP ]] && rm -rf "$TMP"
  return 0
}
say() { printf '==> %s\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

main "$@"
