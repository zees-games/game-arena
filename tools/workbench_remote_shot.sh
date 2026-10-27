#!/usr/bin/env bash
# Render the remote admin panel to screenshots/workbench_remote.png.
# xvfb-run: --headless has a null renderer and saves empty frames.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p screenshots
exec timeout 120 xvfb-run -a godot --path . --resolution 1600x900 --script tools/workbench_remote_shot.gd
