#!/bin/bash
# Publishes this game's pack (id game-arena). Addons are host-owned (the client shell and servers carry them, arena-weapons included),
# so they are left out. Examples, tests, tools, docs and README art are not runtime content.
# Map content ships as its own packs (arena-surf-dm-maps, arena-dm-maps: one per map, named by a server or solo-listed), never in this
# one: MAP_LINKS are the links dot-bootstrap makes to those repositories (every `# bootstrap-link:` path in .gitignore), about 430 MiB.
# A gitignore line without a trailing slash does not hide them from the publisher, and heavy publishes from a copy with links resolved,
# so they are named here. headless_delivered fails when a link in .gitignore is missing from MAP_LINKS.
#   tools/publish.sh --version V [publish_pack.sh flags, e.g. --site URL --token-file F --lock F --dry-run]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAP_LINKS=(maps/imported maps/imported_dm worlds worlds_dm .stores)
X=(); for d in examples tests tools docs images screenshots shots_boot ci .github addons "${MAP_LINKS[@]}"; do X+=(--exclude-dir "$d"); done
exec "$HERE/../dot-cloud/tools/publish_pack.sh" publish --source "$HERE" --id game-arena "${X[@]}" --lock "$HERE/content.lock.json" "$@"
