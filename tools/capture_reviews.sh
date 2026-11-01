#!/usr/bin/env bash
# Weapon reload/fire clips for the nightly /reviews page; see dot-game/tools/capture_reviews.sh.
cd "$(dirname "$0")/.." && exec bash ../dot-game/tools/capture_reviews.sh "$@"
