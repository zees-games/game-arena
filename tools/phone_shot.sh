#!/usr/bin/env bash
# One phone-size touch frame of the real client: tools/phone_shot.sh [--scene=... --out=... --set=map=dm_box]
exec bash "$(dirname "$0")/../addons/dot_game/tools/dot_game_phone_shot.sh" "$@"
