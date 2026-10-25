#!/usr/bin/env bash
# Ride caches for every imported surf map: explore the edges, plan each in its own process, merge. See surf_rides_all.py (-j, --maps, --replan, --wrap).
# Nightly/regen step: a map with a complete cache is skipped, so only new surf maps cost time (about 12 min explore, 6 to 30 min per edge, edges in parallel).
exec python3 -I "$(dirname "$0")/surf_rides_all.py" "$@"
