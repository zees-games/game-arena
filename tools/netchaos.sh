#!/usr/bin/env bash
#
# netchaos.sh: several real arena clients on separate machines against one real dedicated server,
# under latency, jitter, loss, reordering, duplication and a blackout. Run it through heavy:
#
#   heavy -- tools/netchaos.sh [--profile clean,lossy100,awful400] [--remote 2] [--local 1]
#                              [--boxes staging,staging02] [--active 30] [--settle 8] [--post] [--out DIR]
#   tools/netchaos.sh selftest [staging|staging02]    the tc filter on one box with a harmless profile
#   tools/netchaos.sh profiles                        list the profiles
#
# Exit 1 when any assertion of any profile fails. docs/testing.md "Network chaos" says what it
# proves and why impairing only the game's ip:port is safe on a WiFi box.
set -u
cd "$(dirname "$0")/.." || exit 2
ROOT=$PWD
GODOT=${GODOT:-godot}
KEY=${GPU_KEY:-$HOME/.ssh/gpu-laptop}
SSH_OPTS=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=6)
PORT=${NC_PORT:-27210}
REMOTE_N=2 LOCAL_N=1 ACTIVE=30 SETTLE=8 LEAD=${NC_LEAD:-50}
BOXES=staging,staging02
PROFILES=clean,lossy100,awful400
OUT=
POST=0
BLACKOUT_SECONDS=3

# profile NAME -> one-way netem (each direction), and the seconds of full blackout at mid-run.
# One-way delay is half the profile's round trip.
profile_netem() {
	BLACKOUT=0
	case $1 in
		clean)     NETEM="" ;;
		lossy100)  NETEM="delay 50ms 5ms loss 3%" ;;
		jitter200) NETEM="delay 100ms 25ms distribution normal loss 8%" ;;
		awful400)  NETEM="delay 200ms 40ms loss 15% reorder 25% 50% duplicate 3%" ;;
		bwcap)     NETEM="delay 50ms 5ms rate 256kbit limit 60" ;;
		blackout)  NETEM="delay 50ms 5ms loss 1%"; BLACKOUT=$BLACKOUT_SECONDS ;;
		*) echo "unknown profile $1" >&2; return 1 ;;
	esac
}

die() { echo "netchaos: $*" >&2; exit 2; }
say() { echo "netchaos: $*"; }

box_host() { case $1 in staging) echo gamedev@staging.deacon.internal ;; staging02) echo gamedev@staging02.deacon.internal ;; *) die "unknown box $1" ;; esac; }
rssh() { local b=$1; shift; ssh "${SSH_OPTS[@]}" "$(box_host "$b")" "$@"; }
box_ip() { getent hosts "$(box_host "$1" | cut -d@ -f2)" | awk '{print $1}'; }
# tc on a box: the script is piped, so the box needs nothing installed but sudo and tc.
tc_box() { local b=$1; shift; ssh "${SSH_OPTS[@]}" "$(box_host "$b")" "bash -s -- $(printf '%q ' "$@")" < tools/netchaos_tc.sh; }
tc_local() { bash tools/netchaos_tc.sh "$@"; }
dev_for() { ip route get "$1" | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1; }
dev_on() { rssh "$1" "ip route get $2" | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1; }
src_to() { ip route get "$1" | sed -n 's/.* src \([^ ]*\).*/\1/p' | head -1; }
reachable() { rssh "$1" true 2>/dev/null; }

selftest() {
	local b=${1:-staging} ip dev srv t0 t1
	reachable "$b" || die "$b unreachable"
	ip=$(box_ip "$b"); srv=$(src_to "$ip"); dev=$(dev_on "$b" "$srv")
	say "selftest on $b ($ip) device $dev, server side $srv"
	tc_box "$b" check "$dev" || die "$b is not clean before the test"
	ping -c6 -q "$ip" | tail -1
	tc_box "$b" apply "$dev" 40 "delay 1ms" "ip=$srv,dport=27999" || die "apply failed"
	ping -c6 -q "$ip" | tail -1
	t0=$(date +%s%N); rssh "$b" true; t1=$(date +%s%N); say "ssh round trip while armed: $(((t1 - t0) / 1000000)) ms"
	rssh "$b" 'for p in 27999 27998 22000; do echo x > /dev/udp/'"$srv"'/$p; done; sleep 0.3; sudo -n tc -s qdisc show dev '"$dev"' | grep -A1 netem | tail -1'
	say "(1 pkt expected on netem: only port 27999 matches)"
	tc_box "$b" clear "$dev" || die "NOT CLEAN after clear"
	say "selftest ok"
}

[[ ${1:-} == selftest ]] && { selftest "${2:-staging}"; exit $?; }
[[ ${1:-} == profiles ]] && { for p in clean lossy100 jitter200 awful400 bwcap blackout; do profile_netem $p; echo "$p: ${NETEM:-none} (each way)${BLACKOUT:+ blackout ${BLACKOUT}s}"; done; exit 0; }

while [[ $# -gt 0 ]]; do
	case $1 in
		--profile) PROFILES=$2; shift 2 ;;
		--remote) REMOTE_N=$2; shift 2 ;;
		--local) LOCAL_N=$2; shift 2 ;;
		--clients) REMOTE_N=$(($2 - 1)); LOCAL_N=1; shift 2 ;;
		--boxes) BOXES=$2; shift 2 ;;
		--active) ACTIVE=$2; shift 2 ;;
		--settle) SETTLE=$2; shift 2 ;;
		--blackout) BLACKOUT_SECONDS=$2; shift 2 ;;
		--out) OUT=$2; shift 2 ;;
		--port) PORT=$2; shift 2 ;;
		--post) POST=1; shift ;;
		*) die "unknown option $1" ;;
	esac
done
OUT=${OUT:-$ROOT/.godot/netchaos/$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"

# Boxes that answer, in order; remote clients are spread over them.
USE=()
if (( REMOTE_N > 0 )); then
	for b in ${BOXES//,/ }; do
		if reachable "$b"; then USE+=("$b"); else say "$b unreachable, skipped"; fi
	done
	((${#USE[@]})) || die "no remote box answers; use --remote 0 for a local-only run"
fi

SERVER_PID=""
CLEANED=0
LAST_DEV_LOCAL=""
declare -A BOXDEV BOXIP BOXSRV BOXOFF

cleanup() {
	((CLEANED)) && return
	CLEANED=1
	[[ -n $SERVER_PID ]] && kill "$SERVER_PID" 2>/dev/null
	pkill -f "netchaos_client.tscn" 2>/dev/null
	for b in "${USE[@]}"; do rssh "$b" 'pkill -f netchaos_client.tscn' 2>/dev/null; done
	clear_all
}

# Clears every device this run armed and prints the verdict for each; the watchdogs are the
# second line if this never runs.
clear_all() {
	CLEAN_OK=1
	for b in "${USE[@]}"; do
		[[ -n ${BOXDEV[$b]:-} ]] || continue
		tc_box "$b" clear "${BOXDEV[$b]}" >"$OUT/tc-clear-$b.txt" 2>&1 || CLEAN_OK=0
		tr '\n' ' ' <"$OUT/tc-clear-$b.txt"; echo
	done
	if [[ -n $LAST_DEV_LOCAL ]]; then
		tc_local clear "$LAST_DEV_LOCAL" >"$OUT/tc-clear-dev02.txt" 2>&1 || CLEAN_OK=0
		tr '\n' ' ' <"$OUT/tc-clear-dev02.txt"; echo
	fi
}
CLEAN_OK=1
trap cleanup EXIT INT TERM

for b in "${USE[@]}"; do
	BOXIP[$b]=$(box_ip "$b")
	BOXSRV[$b]=$(src_to "${BOXIP[$b]}")
	BOXDEV[$b]=$(dev_on "$b" "${BOXSRV[$b]}")
	[[ -n ${BOXDEV[$b]} ]] || die "no route from $b to the server"
	LAST_DEV_LOCAL=$(dev_for "${BOXIP[$b]}")
done
SERVER_IP=127.0.0.1; ((${#USE[@]})) && SERVER_IP=${BOXSRV[${USE[0]}]}

say "pre-check: tc must be clean on every box"
for b in "${USE[@]}"; do tc_box "$b" check "${BOXDEV[$b]}" || die "$b not clean before the run"; done
[[ -n $LAST_DEV_LOCAL ]] && { tc_local check "$LAST_DEV_LOCAL" || die "dev02 not clean before the run"; }

for b in "${USE[@]}"; do
	say "syncing the project to $b"
	GPU_BOX=$b "$ROOT/../gpu.sh" sync game-arena >/dev/null || die "sync to $b failed"
	# Every run, not only without a cache: a class that moved addon leaves a stale cache.
	rssh "$b" '(cd ~/gpu/godot/game-arena && timeout 900 ~/gpu/bin/godot --headless --path . --import >/dev/null 2>&1 </dev/null); mkdir -p /tmp/netchaos'
done

# Clock offsets: a box's unix time minus this machine's, corrected for half the ssh round trip.
for b in "${USE[@]}"; do
	t0=$(date +%s.%N); r=$(rssh "$b" 'date +%s.%N'); t1=$(date +%s.%N)
	BOXOFF[$b]=$(python3 -c "print(round($r - ($t0 + $t1) / 2, 3))")
	say "clock offset $b: ${BOXOFF[$b]} s"
done

overall=0
for prof in ${PROFILES//,/ }; do
	profile_netem "$prof" || exit 2
	RUN=$OUT/$prof
	mkdir -p "$RUN/srv"
	say "=== profile $prof: ${NETEM:-no impairment} (each way), $REMOTE_N remote + $LOCAL_N local clients"
	MAXSEC=$((LEAD + ACTIVE + SETTLE + 150))

	"$GODOT" --headless --path "$ROOT" res://tools/netchaos_server.tscn -- --port "$PORT" --data "$RUN/srv" >"$RUN/server.log" 2>&1 &
	SERVER_PID=$!
	for _ in $(seq 1 120); do grep -q "netchaos server: ready" "$RUN/server.log" 2>/dev/null && break; kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 1; done
	grep -q "netchaos server: ready" "$RUN/server.log" || { say "server did not start"; tail -5 "$RUN/server.log"; overall=1; continue; }

	if [[ -n $NETEM ]]; then
		specs_srv=()
		for b in "${USE[@]}"; do
			tc_box "$b" apply "${BOXDEV[$b]}" "$MAXSEC" "$NETEM" "ip=${BOXSRV[$b]},dport=$PORT" || { say "apply on $b failed"; overall=1; }
			specs_srv+=("ip=${BOXIP[$b]},sport=$PORT")
		done
		tc_local apply "$LAST_DEV_LOCAL" "$MAXSEC" "$NETEM" "${specs_srv[@]}" || { say "apply on dev02 failed"; overall=1; }
	fi

	START=$(python3 -c "import time; print(round(time.time() + $LEAD, 3))")
	FINISH=$(python3 -c "print($START + $ACTIVE + $SETTLE)")
	python3 -c "print($FINISH - 1.5)" >"$RUN/srv/truth_at"
	CLIENT_PIDS=()
	NAMES=()
	idx=0
	for ((i = 0; i < REMOTE_N; i++)); do
		b=${USE[$((i % ${#USE[@]}))]}
		n="R$i"
		NAMES+=("$n:$b")
		s_box=$(python3 -c "print(round($START + ${BOXOFF[$b]}, 3))")
		rssh "$b" "flock -s -w 300 ~/gpu/.lock timeout $((LEAD + ACTIVE + SETTLE + 90)) ~/gpu/bin/godot --headless --path ~/gpu/godot/game-arena res://tools/netchaos_client.tscn -- --server ${BOXSRV[$b]}:$PORT --name $n --start-at $s_box --active $ACTIVE --settle $SETTLE --out /tmp/netchaos/$prof-$n.json" \
			>"$RUN/client-$n.log" 2>&1 &
		CLIENT_PIDS+=($!)
	done
	for ((i = 0; i < LOCAL_N; i++)); do
		n="L$i"
		NAMES+=("$n:local")
		timeout $((LEAD + ACTIVE + SETTLE + 90)) "$GODOT" --headless --path "$ROOT" res://tools/netchaos_client.tscn -- \
			--server "127.0.0.1:$PORT" --name "$n" --start-at "$START" --active "$ACTIVE" --settle "$SETTLE" --out "$RUN/client-$n.json" \
			>"$RUN/client-$n.log" 2>&1 &
		CLIENT_PIDS+=($!)
	done

	if ((BLACKOUT > 0)); then
		( sleep "$(python3 -c "import time; print(max(0, $START + $ACTIVE / 2 - time.time()))")"
		  for b in "${USE[@]}"; do tc_box "$b" netem "${BOXDEV[$b]}" "loss 100%" >/dev/null 2>&1 & done
		  tc_local netem "$LAST_DEV_LOCAL" "loss 100%" >/dev/null 2>&1
		  sleep "$BLACKOUT"
		  for b in "${USE[@]}"; do tc_box "$b" netem "${BOXDEV[$b]}" "$NETEM" >/dev/null 2>&1 & done
		  tc_local netem "$LAST_DEV_LOCAL" "$NETEM" >/dev/null 2>&1
		  wait ) &
		BO_PID=$!
	fi

	for p in "${CLIENT_PIDS[@]}"; do wait "$p"; done
	((BLACKOUT > 0)) && wait "$BO_PID" 2>/dev/null

	# Netem's own counters, before the qdisc goes: what was really injected.
	: >"$RUN/netem.txt"
	for b in "${USE[@]}"; do
		[[ -n $NETEM ]] && { echo "$b up:"; rssh "$b" "sudo -n tc -s qdisc show dev ${BOXDEV[$b]}" | grep -A1 netem; } >>"$RUN/netem.txt" 2>&1
	done
	[[ -n $NETEM && -n $LAST_DEV_LOCAL ]] && { echo "dev02 down:"; sudo -n tc -s qdisc show dev "$LAST_DEV_LOCAL" | grep -A1 netem; } >>"$RUN/netem.txt" 2>&1

	touch "$RUN/srv/stop"
	wait "$SERVER_PID" 2>/dev/null
	SERVER_PID=""

	# Remove impairment first, then fetch the remote reports over a clean path.
	clear_all >"$RUN/tc-after.txt"; cat "$RUN/tc-after.txt"
	((CLEAN_OK)) || { say "TC NOT CLEAN AFTER $prof"; overall=1; }
	for entry in "${NAMES[@]}"; do
		n=${entry%%:*} b=${entry#*:}
		[[ $b == local ]] || rssh "$b" "cat /tmp/netchaos/$prof-$n.json" >"$RUN/client-$n.json" 2>/dev/null
	done

	python3 -I tools/netchaos_eval.py "$RUN" "$prof" "${NAMES[@]}" || overall=1
	[[ -n $NETEM ]] && cat "$RUN/netem.txt" | tr '\n' ' ' | sed 's/Sent/\nSent/g' | grep -o "Sent [0-9]* bytes [0-9]* pkt (dropped [0-9]*" | tr '\n' ';' && echo
done

cleanup
python3 -I tools/netchaos_eval.py "$OUT" --all ${PROFILES//,/ } || overall=1
if ((POST)); then
	# The /qa board's "suite" kind takes payload.json as written: failures are named "netchaos <profile>".
	ssh dev01 "f=\$(mktemp) && cat >\$f && QA_URL=http://127.0.0.1:3010 QA_COMMIT=$(git rev-parse HEAD) ~/stack/nightly/scripts/qa-post.sh suite game-arena \$f; r=\$?; rm -f \$f; exit \$r" <"$OUT/payload.json" || say "qa post failed"
fi
say "outputs in $OUT"
exit "$overall"
