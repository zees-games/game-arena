#!/usr/bin/env bash
# Runs ON a box (piped through ssh by netchaos.sh, or directly on dev02). Impairs only UDP traffic
# to given ip:port pairs, never the interface: a prio qdisc sends everything to band 1 (plain),
# and a u32 filter sends the matches to band 3, which carries netem. Every apply arms a detached
# watchdog that removes the qdisc after MAXSEC even if the controller and its ssh are gone.
#
#   netchaos_tc.sh check DEV
#   netchaos_tc.sh apply DEV MAXSEC "NETEM ARGS" ip=A.B.C.D,dport=P|ip=A.B.C.D,sport=P ...
#   netchaos_tc.sh netem DEV "NETEM ARGS"       change the impairment in place (blackout)
#   netchaos_tc.sh clear DEV
set -u
TC=(sudo -n tc)
MAJOR=7e57
MINOR=7e58
action=${1:?action}
dev=${2:?device}
pidfile=/tmp/netchaos_wd_$dev.pid

ours() { "${TC[@]}" qdisc show dev "$dev" | grep -q "prio $MAJOR:"; }

report() {
	echo "tc[$dev]: $("${TC[@]}" qdisc show dev "$dev" | head -1)"
	if ours; then echo "tc[$dev]: IMPAIRED"; else echo "tc[$dev]: clean"; fi
}

case $action in
check)
	report
	ours && exit 1
	[[ -z "$("${TC[@]}" filter show dev "$dev" 2>/dev/null)" ]] || { echo "tc[$dev]: filters present"; exit 1; }
	;;
apply)
	maxsec=$3 netem=$4
	shift 4
	root=$("${TC[@]}" qdisc show dev "$dev" | head -1)
	case $root in
		*" noqueue "*|*" mq "*|*" pfifo_fast "*|*" fq_codel "*|*" fq "*) ;;
		*) echo "tc[$dev]: refusing, root qdisc is not a default one: $root"; exit 2 ;;
	esac
	[[ -z "$("${TC[@]}" filter show dev "$dev" 2>/dev/null)" ]] || { echo "tc[$dev]: refusing, filters already present"; exit 2; }
	"${TC[@]}" qdisc add dev "$dev" root handle $MAJOR: prio bands 3 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 || exit 3
	# shellcheck disable=SC2086
	"${TC[@]}" qdisc add dev "$dev" parent $MAJOR:3 handle $MINOR: netem $netem || { "${TC[@]}" qdisc del dev "$dev" root; exit 3; }
	for spec in "$@"; do
		ip=${spec#ip=}; ip=${ip%%,*}
		port=${spec##*,}
		match="dport"
		[[ $port == sport=* ]] && match="sport"
		port=${port#*=}
		if ! "${TC[@]}" filter add dev "$dev" protocol ip parent $MAJOR: prio 1 u32 \
			match ip protocol 17 0xff match ip dst "$ip/32" match ip "$match" "$port" 0xffff flowid $MAJOR:3; then
			"${TC[@]}" qdisc del dev "$dev" root
			exit 3
		fi
	done
	# The watchdog deletes only a qdisc that is still ours.
	setsid nohup bash -c "sleep $maxsec; if sudo -n tc qdisc show dev $dev | grep -q 'prio $MAJOR:'; then sudo -n tc qdisc del dev $dev root; fi; rm -f $pidfile" >/dev/null 2>&1 </dev/null &
	echo $! > "$pidfile"
	report
	;;
netem)
	# shellcheck disable=SC2086
	ours && "${TC[@]}" qdisc change dev "$dev" parent $MAJOR:3 handle $MINOR: netem $3
	;;
clear)
	if [[ -f $pidfile ]]; then
		pkill -P "$(cat "$pidfile")" sleep 2>/dev/null
		kill "$(cat "$pidfile")" 2>/dev/null
		rm -f "$pidfile"
	fi
	ours && "${TC[@]}" qdisc del dev "$dev" root
	report
	ours && exit 1
	exit 0
	;;
*) echo "unknown action $action"; exit 64 ;;
esac
