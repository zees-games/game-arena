#!/bin/bash
# Publishes this game's pack (id game-arena). Addons are host-owned (the client shell and servers carry them, arena-weapons included),
# so they are left out; maps/imported and maps/imported_dm are gitignored links to the map packs and never ship from here.
# Examples, tests, tools, docs and README art are not runtime content.
#   tools/publish.sh --version V [publish_pack.sh flags, e.g. --site URL --token-file F --lock F --dry-run]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
X=(); for d in examples tests tools docs images screenshots shots_boot ci .github addons; do X+=(--exclude-dir "$d"); done
exec "$HERE/../dot-cloud/tools/publish_pack.sh" publish --source "$HERE" --id game-arena "${X[@]}" --lock "$HERE/content.lock.json" "$@"
