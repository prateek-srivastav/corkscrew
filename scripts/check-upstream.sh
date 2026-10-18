#!/bin/bash
# Lists the components pinned in runtime-pins.env that have a newer upstream release, one per line,
# tab-separated: name, pinned version, latest version, release page, note. Exits 1 when a source
# couldn't be read, after checking the others. .github/workflows/upstream.yml runs it every week and
# opens an issue for each line. Needs curl and gh (GitHub's API).
set -uo pipefail
source "$(dirname "$0")/runtime-pins.env"

failed=0

# report NAME PINNED LATEST URL [NOTE]: prints a line when LATEST is newer than PINNED.
report() {
  local name=$1 pinned=$2 latest=$3 url=$4 note=${5:-}
  if [[ -z $latest ]]; then
    echo "couldn't find the latest $name release" >&2
    failed=1
    return
  fi
  [[ $latest != "$pinned" && $(printf '%s\n%s\n' "$pinned" "$latest" | sort -V | tail -1) == "$latest" ]] || return 0
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$pinned" "$latest" "$url" "$note"
}

# latest_tag REPO: the tag of a GitHub repository's latest release (pre-releases don't count).
latest_tag() { gh api "repos/$1/releases/latest" --jq .tag_name; }

# CodeWeavers' source page links only the current release.
crossover=$(curl -fsSL https://www.codeweavers.com/crossover/source |
  grep -oE 'crossover-sources-[0-9][0-9.]*[0-9]\.tar\.gz' | sed -E 's/crossover-sources-(.*)\.tar\.gz/\1/' | sort -uV | tail -1)
report CrossOver "$CROSSOVER_VERSION" "$crossover" https://www.codeweavers.com/crossover/source

tag=$(latest_tag 3Shain/dxmt)
report DXMT "$DXMT_VERSION" "${tag#v}" "https://github.com/3Shain/dxmt/releases/tag/$tag"

tag=$(latest_tag Gcenx/DXVK-macOS)
report DXVK "$DXVK_VERSION" "${tag#v}" "https://github.com/Gcenx/DXVK-macOS/releases/tag/$tag"

tag=$(latest_tag KhronosGroup/MoltenVK)
report MoltenVK "$MOLTENVK_VERSION" "${tag#v}" "https://github.com/KhronosGroup/MoltenVK/releases/tag/$tag"

tag=$(latest_tag wine-mono/wine-mono)
report "Wine Mono" "$WINE_MONO_VERSION" "${tag#wine-mono-}" "https://github.com/wine-mono/wine-mono/releases/tag/$tag" \
  "The CrossOver Wine asks for one Wine Mono version (dlls/appwiz.cpl/addons.c). Update it with a CrossOver that asks for this one."

# Apple's page names only the major version ("Game Porting Toolkit 4"), so minor releases aren't seen.
gptk=$(curl -fsSL https://developer.apple.com/games/game-porting-toolkit/ |
  grep -oE 'Game Porting Toolkit [0-9]+(\.[0-9]+)*' | sed 's/Game Porting Toolkit //' | sort -uV | tail -1)
report "Game Porting Toolkit" "$GPTK_VERSION" "$gptk" https://developer.apple.com/games/game-porting-toolkit/ \
  "Download its image from Apple's developer site with an Apple Account (pins: GPTK_VERSION, GPTK_DMG_SHA256)."

exit $failed
