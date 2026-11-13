#!/usr/bin/env bash
# Profile a CS:S dedicated server (srcds, app 232330) on the Pterodactyl node from its console.
# For each "bot_quota:sv_maxupdaterate" config: warm up, vprof_reset, run 60 s with `stats` every 10 s,
# then vprof_generate_report, status and net_stats. Baseline and how to read it:
# docs/css-dedicated-server-baseline.md
#
#   tools/css_server_profile.sh                        # 31:66 31:33 15:66 15:33, then stop the server
#   tools/css_server_profile.sh --configs "31:66" --secs 120 --keep
#
# Uses only the panel's client API (power, console command, file read/delete). The client key is read
# from ~gamedev/.config/pterodactyl/client_key (through sudo -u gamedev if needed). It is passed to curl
# on a file descriptor, so it never appears in argv or in the output.
# Console output is captured with con_logfile into cstrike/, read back over the files API, then deleted.
set -euo pipefail

PANEL=${CSS_PANEL:-https://panel.tmcdev.net}
SERVER=${CSS_SERVER:-0f7b8298}          # panel identifier of "CSS Profile (private test)"
KEY_FILE=${CSS_KEY_FILE:-/home/gamedev/.config/pterodactyl/client_key}
OUT_ROOT=${CSS_OUT:-/home/christian/perf-logs/external/cstrike/server-pterodactyl}
CONFIGS="31:66 31:33 15:66 15:33"
SECS=60; STEP=10; WARM=30; KEEP=0; MAP=""

while [ $# -gt 0 ]; do
	case $1 in
		--configs) CONFIGS=$2; shift 2 ;;
		--secs) SECS=$2; shift 2 ;;
		--warm) WARM=$2; shift 2 ;;
		--map) MAP=$2; shift 2 ;;
		--out) OUT_ROOT=$2; shift 2 ;;
		--keep) KEEP=1; shift ;;
		-h|--help) sed -n 2,13p "$0"; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

if [ -r "$KEY_FILE" ]; then KEY=$(cat "$KEY_FILE"); else KEY=$(sudo -u gamedev cat "$KEY_FILE"); fi
api() { # METHOD PATH [curl args...]
	local m=$1 p=$2; shift 2
	curl -sS --fail-with-body -X "$m" -H @<(printf 'Authorization: Bearer %s\n' "$KEY") \
		-H "Accept: application/json" "$PANEL/api/client/servers/$SERVER$p" "$@"
}
json_cmd() { python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1]}))' "$1"; }
cmd() { api POST /command -H "Content-Type: application/json" --data "$(json_cmd "$1")" >/dev/null; }
power() { api POST /power -H "Content-Type: application/json" --data "{\"signal\":\"$1\"}" >/dev/null; }
resources() { api GET /resources | python3 -c 'import json,sys; a=json.load(sys.stdin)["attributes"]; r=a["resources"]; print(a["current_state"], r["cpu_absolute"], r["memory_bytes"]//1048576)'; }
state() { resources | cut -d' ' -f1; }

stamp=$(date +%Y%m%d-%H%M%S)
out="$OUT_ROOT/$stamp"
mkdir -p "$out"
echo "out: $out"

if [ "$(state)" != running ]; then
	power start
	for _ in $(seq 60); do [ "$(state)" = running ] && break; sleep 3; done
	[ "$(state)" = running ] || { echo "server did not reach running" >&2; exit 1; }
	sleep 20
fi
if [ -n "$MAP" ]; then cmd "changelevel $MAP"; sleep 20; fi

# Private LAN-only test server: cheats on for vprof, no autobalance, bots fill every slot.
for c in "sv_cheats 1" "bot_difficulty 2" "mp_autoteambalance 0" "mp_limitteams 0" "bot_quota_mode fill" \
	"bot_join_after_player 0" "mp_timelimit 0" "mp_maxrounds 0" "mp_freezetime 0" "vprof_on"; do
	cmd "$c"
done

printf 'config\tbots\trate\tticks\tserver_frame_ms\tgameframe_ms\tbots_ms\trun_command_ms\tsend_clients_ms\tboxtrace_per_tick\tframe_peak_ms\tpanel_cpu_pct\tpanel_ms_tick\tmem_mb\tload1\n' > "$out/summary.tsv"
{
	echo "host=$(hostname) nproc=$(nproc) date=$(date -Is)"
	echo "load=$(cut -d' ' -f1-3 /proc/loadavg)"
	echo "server=$SERVER secs=$SECS step=$STEP warm=$WARM configs=$CONFIGS"
} > "$out/meta.txt"

for conf in $CONFIGS; do
	quota=${conf%%:*}; rate=${conf##*:}
	tag="q${quota}_r${rate}"
	log="css_prof_${stamp}_${tag}.log"
	echo "== $tag ($(date +%T))"
	cmd "bot_quota $quota"; cmd "sv_maxupdaterate $rate"; cmd "sv_minupdaterate 10"
	sleep "$WARM"
	cmd "con_logfile $log"
	cmd "status"
	cmd "vprof_reset"
	: > "$out/$tag.panel_cpu.txt"
	for t in $(seq 0 "$STEP" "$SECS"); do
		cmd "stats"
		echo "t=$t $(resources)" >> "$out/$tag.panel_cpu.txt"
		[ "$t" -lt "$SECS" ] && sleep "$STEP"
	done
	cmd "vprof_generate_report"
	cmd "status"
	cmd "net_stats"   # client-only: srcds answers Unknown command
	sleep 3
	cmd 'con_logfile ""'
	sleep 1
	api GET "/files/contents?file=%2Fcstrike%2F$log" > "$out/$tag.console.log"
	api POST /files/delete -H "Content-Type: application/json" --data "{\"root\":\"/cstrike\",\"files\":[\"$log\"]}" >/dev/null || true
	# ms per tick from vprof's first inclusive table; ticks = _Host_RunFrame_Server calls.
	tr -d '\r' < "$out/$tag.console.log" | awk -v tag="$tag" -v q="$quota" -v r="$rate" \
		-v load1="$(cut -d' ' -f1 /proc/loadavg)" -v cpuf="$out/$tag.panel_cpu.txt" '
		/sorted by time \(including children\)/ { if (!done) on = 1; next }
		/sorted by time \(without children\)/ { if (on) done = 1; on = 0 }
		on && NF >= 11 && $(NF-9) ~ /^[0-9]+$/ {
			name = $1; for (i = 2; i <= NF - 10; i++) name = name " " $i
			calls[name] = $(NF-9); incl[name] = $(NF-7); peak[name] = $NF
		}
		function per(pat,   k) { for (k in incl) if (k ~ pat) return incl[k] / t; return -1 }
		END {
			t = calls["_Host_RunFrame_Server"]
			if (t == 0) { print tag ": no vprof table in console log" > "/dev/stderr"; t = 1 }
			while ((getline l < cpuf) > 0) { split(l, a, " "); if (a[1] != "t=0") { s += a[3]; m = a[4]; k++ } }
			pc = k ? s / k : 0
			printf "%s\t%d\t%d\t%d\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%d\t%.2f\t%.1f\t%.2f\t%d\t%s\n", tag, q, r, t,
				per("^_Host_RunFrame_Server$"), per("GameFrame$"), per("^CBotManager::StartFrame$"),
				per("PlayerRunCommand$"), per("^SendClientMessages$"), calls["BoxTrace"] / t, peak["_Host_RunFrame_Server"],
				pc, pc / 100 * 1000 / 66.67, m, load1
		}' >> "$out/summary.tsv"
	tail -1 "$out/summary.tsv"
done

if [ "$KEEP" = 0 ]; then
	power stop
	echo "server stopped; this script starts it again (or panel > CSS Profile > Start)"
fi
column -t "$out/summary.tsv"
