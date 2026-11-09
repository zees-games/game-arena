#!/usr/bin/env bash
# The 16v16 benchmark on a GPU box, windowed with real rendering (gpu.sh run: Xvfb + Vulkan on the
# NVIDIA card), and its per-system table against the owner's profile. Run as gamedev, from a checkout:
#   tools/perf_bench.sh [--box staging02] [--headless] [--tag T] [--ref owner.json] [-- perf_bench args]
#   tools/perf_bench.sh --ab DIR_A DIR_B [-n 3] [--box staging02] [-- perf_bench args]
# --debug runs Godot with -d, which the script-function table (-- --script-top 40) needs; it slows GDScript.
# --ab runs A,B,A,B... (n each) on one pinned box and prints per-system mean deltas.
# DIR may carry extra bench args after "::", e.g. ~/wt/game-arena-x::--bots 15.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
gpu=${GPU_SH:-/home/gamedev/godot/dot-bootstrap/tools/gpu.sh}
box=staging02
headless=0
debug=0
tag=""
ref=${PERF_BENCH_REF:-/home/christian/perf-logs/arena/profile-20261108160712-051.json}
logs=${PERF_BENCH_LOGS:-/home/gamedev/perf-bench}
ab=0 n=3 dir_a="" dir_b=""
while [[ $# -gt 0 ]]; do
	case $1 in
		--box) box=$2; shift 2 ;;
		--headless) headless=1; shift ;;
		--debug) debug=1; shift ;;
		--tag) tag=$2; shift 2 ;;
		--ref) ref=$2; shift 2 ;;
		--ab) ab=1; dir_a=$2; dir_b=$3; shift 3 ;;
		-n) n=$2; shift 2 ;;
		--) shift; break ;;
		*) echo "perf_bench.sh: unknown option $1" >&2; exit 2 ;;
	esac
done
mkdir -p "$logs"

# One run of the checkout $1 (extra bench args after ::) on $box; prints the log path.
run_one() {
	local spec=$1 label=$2 dir extra=() log
	dir=${spec%%::*}
	[[ $spec == *::* ]] && read -ra extra <<< "${spec#*::}"
	dir=$(cd "$dir" && pwd)
	log="$logs/$(date +%Y%m%d-%H%M%S)-$box-$(basename "$dir")-$label$([[ $headless == 1 ]] && echo -headless).log"
	local hl=()
	[[ $headless == 1 ]] && hl=(--headless)
	[[ $debug == 1 ]] && hl+=(-d)
	echo "perf_bench: $label on $box: $(basename "$dir") ${extra[*]:-} -> $log" >&2
	# gpu.sh takes a project under GODOT_ROOT by name: the checkout's parent and its own name.
	GODOT_ROOT=$(dirname "$dir") GPU_BOX=$box GPU_TIMEOUT=${GPU_TIMEOUT:-900} \
		"$gpu" run "$(basename "$dir")" "${hl[@]}" res://tools/perf_bench.tscn -- --tag "$label" "$@" "${extra[@]}" \
		> "$log" 2>&1 || echo "perf_bench: run exited $? (see $log)" >&2
	grep -q '^PERF_BENCH_REPORT ' "$log" || { echo "perf_bench: no report in $log" >&2; tail -20 "$log" >&2; return 1; }
	echo "$log"
}

if [[ $ab == 0 ]]; then
	log=$(run_one "$here" "${tag:-bench}" "$@")
	python3 "$here/tools/perf_bench_compare.py" "$ref" "$log"
	exit 0
fi

runs=()
for ((i = 1; i <= n; i++)); do
	runs+=("A=$(run_one "$dir_a" A "$@")")
	runs+=("B=$(run_one "$dir_b" B "$@")")
done
python3 "$here/tools/perf_bench_compare.py" --ab "${runs[@]}"
