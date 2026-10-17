#!/bin/bash
# Installs the latest Corkscrew release into /Applications (or ~/Applications when /Applications isn't
# writable), or replaces the one that's there. curl doesn't quarantine what it downloads, so the app
# opens without the "Open Anyway" step that an ad hoc signed app needs after a browser download.
# Usage: curl -fsSL https://prateek-srivastav.github.io/corkscrew/install.sh | bash
# (The Pages workflow publishes this file there; raw.githubusercontent.com/<repo>/main/scripts/install.sh works too.)
# Environment: CORKSCREW_VERSION=0.5.0 to install that version instead of the latest,
# CORKSCREW_APP_DIR=<folder> to install somewhere else, CORKSCREW_NO_OPEN=1 to not open the app after.
# CORKSCREW_RELEASES=<url> replaces https://github.com/<repo>/releases (for testing; needs CORKSCREW_VERSION).
# Usage counts (README "Usage counts"): after an install it sends one anonymous count. DO_NOT_TRACK=1 or
# CORKSCREW_NO_ANALYTICS=1 skips it and turns the app's counts off too; so does the switch in Settings.
# CORKSCREW_ANALYTICS_KEY=<Aptabase app key> replaces the built-in key (A-DEV-… sends to localhost:3000).
set -euo pipefail

APP_ID=io.github.prateek-srivastav.Corkscrew
# Aptabase app key, the same as `Analytics.appKey` in the app. Public: anyone can read it here.
# Empty: no count is sent.
ANALYTICS_KEY=${CORKSCREW_ANALYTICS_KEY:-A-US-8232382106}

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
  # For the install count: an update, and from which version.
  local previous=
  if [[ -d $dir/Corkscrew.app ]]; then
    previous=$(plist_value "$dir/Corkscrew.app" CFBundleShortVersionString)
    previous=${previous:-unknown}
  fi

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
  if analytics_off; then
    # The app counts its first launch: turn that off too, before it opens.
    defaults write "$APP_ID" SendsUsageCounts -bool false
  else
    count_install "$dir/Corkscrew.app" "$previous"
  fi
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

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }

# DO_NOT_TRACK (any value but 0), CORKSCREW_NO_ANALYTICS, or the app's Settings switch turned off.
analytics_off() {
  [[ -n ${CORKSCREW_NO_ANALYTICS:-} ]] && return 0
  [[ -n ${DO_NOT_TRACK:-} && $DO_NOT_TRACK != 0 ]] && return 0
  [[ $(defaults read "$APP_ID" SendsUsageCounts 2>/dev/null) == 0 ]]
}

# One anonymous count of this install, in Aptabase's event format (as the app sends its own): the
# version, update or new, macOS, the Mac model, chip and memory, the language. Aptabase reads the
# country from the connection and doesn't keep the IP address. A few seconds at most; a count that
# fails changes nothing.
count_install() {
  local app=$1 previous=$2 host
  case $ANALYTICS_KEY in
    A-EU-*) host=https://eu.aptabase.com ;;
    A-US-*) host=https://us.aptabase.com ;;
    A-DEV-*) host=http://localhost:3000 ;;
    *) return 0 ;;
  esac
  local version build model chip memory locale debug=false kind=new
  [[ -n $previous ]] && kind=update
  version=$(plist_value "$app" CFBundleShortVersionString)
  build=$(plist_value "$app" CFBundleVersion)
  model=$(sysctl -n hw.model 2>/dev/null || true)
  chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)
  memory=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
  locale=$(defaults read -g AppleLocale 2>/dev/null || true)
  locale=${locale%%[_@-]*}
  [[ -n ${CORKSCREW_RELEASES:-} ]] && debug=true
  local body
  body=$(printf '[{"timestamp":%s,"sessionId":%s,"eventName":"install","systemProps":{"isDebug":%s,"locale":%s,"osName":"macOS","osVersion":%s,"appVersion":%s,"appBuildNumber":%s,"sdkVersion":"corkscrew-install.sh","deviceModel":%s},"props":{"kind":%s,"previous":%s,"chip":%s,"memory_gb":%d}}]' \
    "$(json "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" "$(json "$(date +%s)$(printf '%08d' $(( (RANDOM * 32768 + RANDOM) % 100000000 )))")" \
    "$debug" "$(json "$locale")" "$(json "$(sw_vers -productVersion)")" "$(json "$version")" "$(json "$build")" \
    "$(json "$model")" "$(json "$kind")" "$(json "$previous")" "$(json "$chip")" "$memory")
  curl -fsS --max-time 5 -o /dev/null -X POST -H 'Content-Type: application/json' -H "App-Key: $ANALYTICS_KEY" \
    --data "$body" "$host/api/v0/events" 2>/dev/null || true
}

# A JSON string: printable characters only, without quotes or backslashes.
json() {
  local s=${1//[^[:print:]]/}
  s=${s//\\/}
  s=${s//\"/}
  printf '"%s"' "$s"
}

main "$@"
