#!/usr/bin/env bash
#
# game.sh -- play, host and test this game with one command each.
#
#   ./game.sh                      play it offline, in a window
#   ./game.sh play [-- ARGS]       the same; ARGS go to the game
#   ./game.sh online               run a local server plus the browser client, print the link
#   ./game.sh online down          stop it again
#   ./game.sh server               run a local dedicated server only (Ctrl+C stops it)
#   ./game.sh server check         start the server, load the game, stop; exit 0 if it worked
#   ./game.sh server -- ARGS       ARGS go to dot-server-deploy's ./server (e.g. -- --port 7000)
#   ./game.sh test                 parse every script, then run every test suite
#   ./game.sh test NAME...         run only these suites (e.g. ./game.sh test headless_net)
#   ./game.sh test NAME -- ARGS    pass ARGS to the suite (e.g. test headless_maps -- --map=ID)
#   ./game.sh soak [MAP] [MIN]     bot soak on tools/soak.tscn (report in .godot/test-logs/soak-MAP.json)
#   ./game.sh suites               list the test suites
#   ./game.sh visual [--update] [MAP...]  compare map frames to tests/golden (tools/visual_check.sh)
#   ./game.sh perf [--update] [--post]  frame-time budget on the GPU box vs tests/perf_budget.json
#   ./game.sh netchaos [ARGS]      real server and clients under tc netem loss, jitter, blackout
#   ./game.sh shot [ARGS]          save a screenshot to screenshots/ (tools/shot.sh or tools/screenshot.sh)
#
# Options (before the command):
#   --godot PATH     the Godot 4.7 binary to use (default: $GODOT, then godot on PATH)
#   --timeout SEC    the longest one test suite may run (default 900)
#   --no-parse       skip the parse pass in `test`
#
# `online` and `server` use dot-server-deploy, found next to this repository (or at
# $DOT_SERVER_DEPLOY). dot-bootstrap puts it there. Both rebuild this game's pack first, so
# what you play is what is on disk now.
#
# The same script is in every game repository; only the settings below differ. It is
# GENERATED from dot-game-template/tools/game.sh.in and this repository's game.conf by
# dot-game-template/tools/gen-game-sh.py: edit those, never this file (the generator's
# --check mode fails when they disagree).

# --- This game ------------------------------------------------------------------
# PACK is the game's id in dot-server-deploy (empty if it has no server), EXTRA_PACKS
# are other packs it needs as id:repository pairs, and SUITES are the scenes in
# examples/ that test it.
GAME_NAME="Fatal Contact"
PACK="fatalcontact"
EXTRA_PACKS=""
# headless_lossy plays real ENet through real loss. It was left out while it failed about
# one run in four; since 2026-10-09 it passed 20 of 20 (see docs/testing.md "headless_lossy").
SUITES="headless_config headless_loadout_persist headless_loadout_open headless_workbench headless_mapcfg headless_launch_commands headless_match headless_bots headless_bot_hitreg headless_skins headless_roles headless_net headless_presentation headless_stack headless_admin headless_imported headless_dm_maps headless_ladders headless_delivered headless_workshop dedicated headless_lossy headless_latency headless_feel headless_reload headless_combatfeel headless_recoil headless_ballistics headless_grenades headless_weapondrop headless_weapondrop_rest headless_weapondrop_depth headless_weapondrop_hitch headless_shotfx_hitch headless_shot_nodes headless_stats_hitch headless_weapondrop_death headless_teammenu headless_specflow headless_firemode headless_mapuse headless_jailrelease headless_killcam headless_wallsize headless_bottricks headless_bot_ladders headless_bot_spawn headless_bot_seek headless_aim headless_aimlocal headless_viewarms headless_bot_visible headless_botcap headless_tickrate headless_tickbudget headless_lone_spawn headless_spawn_spread headless_team_spawn headless_corpsewall headless_touch headless_demo_stats headless_ride_pilot headless_ctf headless_cp_orange headless_netaoi headless_botthreads headless_remote_lod headless_profiler_context headless_sim_host headless_slide headless_input_reach"
# --------------------------------------------------------------------------------

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT" || exit 1

GODOT="${GODOT:-godot}"
TIMEOUT=900
PARSE=1
# A suite that legitimately needs at least this long, as name=seconds; a larger
# --timeout still wins.
MIN_TIMEOUTS="headless_imported=3000 headless_bots=2400"
# A suite too long for one run, as name=shard,shard,...: `test NAME` plays each shard as its own
# `examples/NAME.tscn -- --shard SHARD` (up to $SHARD_JOBS at once, default 4) and then runs the
# suite once more as `-- --merge LOG...` over the shards' logs, which holds the whole-run checks.
# `test NAME.SHARD` plays one shard; `test NAME.merge` only the merge over logs already in .godot/test-logs.
# `suites --shards` lists the shards instead of the suite (`hv shard` runs them as separate jobs, then NAME.merge).
SUITE_SHARDS="headless_bots=easy,medium,hard,nightmare headless_imported=rest,maps0,maps1,maps2,maps3 headless_hitbox=stand_still,stand_strafe,crouch_still,crouch_strafe headless_viewarms=w0,w1,w2,w3 headless_bot_hitreg=direct,brain,crowd headless_lossy=windows,moves,rest"
RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; OFF=$'\033[0m'
CR=$'\r\033[K'
[ -t 1 ] || { RED=""; GRN=""; YLW=""; OFF=""; CR=""; }

die() { printf '%s%s%s\n' "$RED" "$1" "$OFF" >&2; exit "${2:-1}"; }
usage() { sed -n '3,/^#   --no-parse/p' "$ROOT/$(basename "${BASH_SOURCE[0]}")" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --godot) GODOT="${2:?--godot needs a path}"; shift 2 ;;
        --godot=*) GODOT="${1#*=}"; shift ;;
        --timeout) TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
        --timeout=*) TIMEOUT="${1#*=}"; shift ;;
        --no-parse) PARSE=0; shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) break ;;
    esac
done

command -v "$GODOT" >/dev/null 2>&1 || die "Godot not found: '$GODOT'. Install Godot 4.7 or pass --godot PATH." 2

cmd="${1:-play}"
[ $# -gt 0 ] && shift

# The addons are links that dot-bootstrap makes. Without them nothing parses, and the
# errors read like a broken game rather than a missing step.
check_addons() {
    local missing=""
    while read -r name; do
        [ -e "addons/$name/plugin.cfg" ] || [ -d "addons/$name" ] || missing="$missing $name"
    done < <(awk '/^# bootstrap-optional/{o=1; next} !o && /^\/addons\/[^\/]+\/?$/{sub("^/addons/",""); sub("/$",""); print} {o=0}' .gitignore 2>/dev/null)
    [ -z "$missing" ] || die "Missing addons:$missing
Run dot-bootstrap first: https://github.com/modcommunity/dot-bootstrap" 2
    # Content links (maps, world): without them the suites run on an empty level set. A git
    # worktree gets them from tools/link_worktree.sh.
    local path src gone=""
    while IFS=$'\t' read -r path src; do
        [ -n "$path" ] && [ ! -e "${path#/}" ] && gone="$gone ${path#/} (from $src)"
    done < <(awk '/^# bootstrap-link: /{src=$3; next} src!="" && /^\//{print $0 "\t" src} {src=""}' .gitignore 2>/dev/null)
    [ -z "$gone" ] || die "Content not linked:$gone
Run dot-bootstrap, or in a git worktree: tools/link_worktree.sh <main checkout>" 2
}

deploy_dir() {
    local dir="${DOT_SERVER_DEPLOY:-$ROOT/../dot-server-deploy}"
    [ -x "$dir/server" ] || die "dot-server-deploy not found at $dir (run its ./setup.sh, or set DOT_SERVER_DEPLOY)." 2
    (cd "$dir" && pwd)
}

# Rebuild this game's pack, and the packs it needs, from the checkouts on disk.
pack_all() {
    [ -n "$PACK" ] || die "$GAME_NAME has no server pack." 2
    local deploy repo id pair
    deploy="$(deploy_dir)"
    for pair in $EXTRA_PACKS; do
        id="${pair%%:*}"; repo="${pair#*:}"
        echo "packing $id"
        (cd "$deploy" && ./server pack "$id" --source "$ROOT/../$repo") >/dev/null || die "could not pack $id"
    done
    "$GODOT" --headless --path . --import >/dev/null 2>&1
    echo "packing $PACK"
    (cd "$deploy" && ./server pack "$PACK" --source "$ROOT") >/dev/null || die "could not pack $PACK"
}

run_suite() {
    # NAME is a suite, or SUITE.SHARD; ARGS (after NAME) go to the scene as user args.
    local scene="$1" base="${1%%.*}"
    shift
    local extra=("$@") _s
    case "$scene" in
        *.merge) extra=(--merge $(for _s in $(shards_of "$base"); do printf '.godot/test-logs/%s.%s.log ' "$base" "$_s"; done) "$@") ;;
        *.*) extra=(--shard "${scene#*.}" "$@") ;;
    esac; extra=(${SUITE_ARGS[@]+"${SUITE_ARGS[@]}"} ${extra[@]+"${extra[@]}"})
    local log out status summary
    [ -f "examples/$base.tscn" ] || { printf '  %s??%s   %s: no examples/%s.tscn\n' "$YLW" "$OFF" "$scene" "$base"; return 1; }
    mkdir -p .godot/test-logs
    log=".godot/test-logs/$scene.log"
    [ -t 1 ] && printf '  ..   %s' "$scene"
    local limit="$TIMEOUT" mkv
    for mkv in $MIN_TIMEOUTS; do
        [ "${mkv%%=*}" = "$base" ] && [ "$limit" -lt "${mkv#*=}" ] && limit="${mkv#*=}"
    done
    timeout "$limit" "$GODOT" --headless --path . "res://examples/$base.tscn" ${extra[@]+-- "${extra[@]}"} >"$log" 2>&1
    status=$?
    summary="$(grep -Eo '[0-9]+ (passed|checks), [0-9]+ failed' "$log" | tail -1)"
    # Section accounting: "N sections entered, M finished" from DotGameCheckSuite._report_sections.
    local acct entered finished
    acct="$(grep -Eo '^[0-9]+ sections entered, [0-9]+ finished' "$log" | tail -1)"
    if [ -n "$acct" ]; then
        entered="${acct%% *}"; finished="$(sed -E 's/.*, ([0-9]+) finished/\1/' <<< "$acct")"
        summary="$summary  [$acct]"
    else
        summary="$summary  [no section accounting]"
    fi
    if [ "$status" -eq 124 ]; then
        out="did not finish within ${limit}s"
    elif [ "$status" -ne 0 ]; then
        out="exited $status"
    elif grep -qE 'SCRIPT ERROR|Parse Error|Lambda capture' "$log"; then
        # A script error aborts one test, not the run, so the suite can still exit 0.
        out="script error in the output"
    elif grep -qE 'resources still in use at exit|ObjectDB instances? ((were|was) )?leaked|RID allocations? of type .* (were|was) leaked' "$log"; then
        # Exit 0 and "0 failed" with objects left alive: a suite that does not free what it built.
        out="leaked objects at exit (run the scene with --verbose to name them)"
    elif [ -n "$acct" ] && [ "$entered" != "$finished" ]; then
        out="$((entered - finished)) of $entered sections aborted"
    elif grep -qE '^ERROR: [0-9]+ (of [0-9]+ sections finished|checks ran)' "$log"; then
        out="section or check count does not match the declared total"
    else
        printf '%s  %sok%s   %s  %s\n' "$CR" "$GRN" "$OFF" "$scene" "$summary"
        return 0
    fi
    printf '%s  %sFAIL%s %s: %s  %s\n' "$CR" "$RED" "$OFF" "$scene" "$out" "$summary"
    grep -E 'FAIL|SCRIPT ERROR|Parse Error|ERROR' "$log" | head -15 | sed 's/^/       /'
    printf '       full log: %s\n' "$log"
    return 1
}

PARSE_NOISE='ObjectDB instances?( were| was)? leaked|resources still in use|Pages in use exist at exit|at: (cleanup|clear|~PagedAllocator)|Text-based project'

# Prints each script that does not parse and returns how many. ANY output for a script,
# past the noise above, is a failure: a warning-as-error reads as nothing else.
parse_all() {
    local fails=0 f out tool=addons/dot_core/tools/dot_parse_all.gd
    local scripts
    scripts="$(git ls-files '*.gd' 2>/dev/null || find . -name '*.gd' -not -path './.godot/*' -not -path './addons/*' | sed 's|^\./||')"
    if [ -f "$tool" ] && [ -z "${PARSE_PER_FILE:-}" ]; then
        # One process loads every script: about ten times faster than a start-up per
        # file (66 scripts: 40 s against 4 s), with the same verdicts. The tool prints a
        # "PARSE> res://path" marker before each script, so output still belongs to a
        # file; what comes before the first marker or after PARSE_END belongs to none.
        local list log line cur="" curout="" finished=0
        list="$(mktemp)"; log="$(mktemp)"
        printf '%s\n' "$scripts" > "$list"
        PARSE_LIST="$list" timeout 900 "$GODOT" --headless --path . --script "res://$tool" >"$log" 2>&1
        while IFS= read -r line; do
            case "$line" in
                'PARSE> '*|'PARSE_END')
                    if [ -n "$cur" ] && [ -n "$curout" ]; then
                        printf '  %sFAIL%s %s\n%s\n' "$RED" "$OFF" "$cur" "$curout"
                        fails=$((fails + 1))
                    fi
                    cur=""; curout=""
                    [ "$line" = PARSE_END ] || cur="${line#PARSE> res://}" ;;
                'PARSED '*) finished=1 ;;
                'PARSE_FAIL '*) [ -n "$cur" ] && [ -z "$curout" ] && curout="$line" ;;
                *)  [ -n "$cur" ] || continue
                    printf '%s\n' "$line" | grep -Ev '^(Godot Engine v|$)' | grep -Eivq "$PARSE_NOISE" || continue
                    curout="${curout:+$curout$'\n'}$line" ;;
            esac
        done < "$log"
        # No PARSED line: the tool itself died or timed out, which is a failure, not a pass.
        if [ "$finished" -eq 0 ]; then
            printf '  %sFAIL%s the parse tool did not finish\n' "$RED" "$OFF"
            tail -n 20 "$log"
            fails=$((fails + 1))
        fi
        rm -f "$list" "$log"
        return "$fails"
    fi
    # An older dot-core without the tool: one process per script.
    while read -r f; do
        [ -n "$f" ] || continue
        out="$(timeout 120 "$GODOT" --headless --path . --check-only --script "res://$f" 2>&1 \
            | grep -Ev '^(Godot Engine v|$)' | grep -Eiv "$PARSE_NOISE")"
        if [ -n "$out" ]; then
            printf '  %sFAIL%s %s\n%s\n' "$RED" "$OFF" "$f" "$out"
            fails=$((fails + 1))
        fi
    done <<< "$scripts"
    return "$fails"
}

# The shards of suite $1 (space separated), empty when it is not sharded.
shards_of() {
    local kv
    for kv in $SUITE_SHARDS; do [ "${kv%%=*}" = "$1" ] && { printf '%s' "${kv#*=}" | tr ',' ' '; return 0; }; done
}

# Plays every shard of suite $1, up to $SHARD_JOBS at once, then the suite over their logs.
run_sharded() {
    local base="$1" shard tmp logs="" bad=0 running=0
    tmp="$(mktemp -d)"
    for shard in $(shards_of "$base"); do
        ( run_suite "$base.$shard" > "$tmp/$shard.out" 2>&1; echo $? > "$tmp/$shard.rc" ) &
        running=$((running + 1))
        [ "$running" -ge "${SHARD_JOBS:-4}" ] && { wait -n; running=$((running - 1)); }
    done
    wait
    for shard in $(shards_of "$base"); do
        cat "$tmp/$shard.out"
        [ "$(cat "$tmp/$shard.rc" 2>/dev/null)" = 0 ] || bad=1
        logs="$logs .godot/test-logs/$base.$shard.log"
    done
    rm -rf "$tmp"
    if [ "$bad" -ne 0 ]; then
        printf '  %sFAIL%s %s: a shard failed, so there is nothing to merge\n' "$RED" "$OFF" "$base"
        return 1
    fi
    run_suite "$base" --merge $logs
}

do_test() {
    # Everything after a literal `--` goes to each suite as user args (e.g. `test headless_maps -- --map=ID`).
    SUITE_ARGS=()
    local names=() a
    while [ $# -gt 0 ]; do
        if [ "$1" = "--" ]; then shift; SUITE_ARGS=("$@"); break; fi
        names+=("$1"); shift
    done
    set -- ${names[@]+"${names[@]}"}
    check_addons
    local fails=0 f out
    echo "importing"
    timeout 600 "$GODOT" --headless --path . --import >/dev/null 2>&1

    if [ "$PARSE" = 1 ] && [ $# -eq 0 ]; then
        echo "parsing every script"
        parse_all
        fails=$?
        [ "$fails" -eq 0 ] && printf '  %sok%s   every script parses\n' "$GRN" "$OFF"
    fi

    echo "running the suites"
    local scene
    for scene in ${*:-$SUITES}; do
        if [ -n "$(shards_of "${scene%.tscn}")" ]; then
            run_sharded "${scene%.tscn}" || fails=$((fails + 1))
            continue
        fi
        run_suite "${scene%.tscn}" || fails=$((fails + 1))
    done

    echo
    [ "$fails" -eq 0 ] && { printf '%sall passed%s\n' "$GRN" "$OFF"; return 0; }
    printf '%s%d failed%s\n' "$RED" "$fails" "$OFF"
    return 1
}

case "$cmd" in
    play)
        check_addons
        [ "${1:-}" = "--" ] && shift
        exec "$GODOT" --path . -- "$@"
        ;;
    online)
        if [ "${1:-}" = "down" ]; then
            exec "$(deploy_dir)/play.sh" down
        fi
        case "${1:-}" in ""|-*) ;; *) PACK="$1"; shift ;; esac
        check_addons
        pack_all
        exec "$(deploy_dir)/play.sh" "$PACK"
        ;;
    server)
        sub="run"
        case "${1:-}" in run|check|config) sub="$1"; shift ;; esac
        check_addons
        pack_all
        [ "${1:-}" = "--" ] && shift
        cd "$(deploy_dir)" || exit 1
        exec ./server "$sub" --game "$PACK" "$@"
        ;;
    test)
        do_test "$@"
        ;;
    soak)
        [ -f tools/soak.tscn ] || die "$GAME_NAME has no bot soak (tools/soak.tscn)." 2
        check_addons
        soak_args=()
        [ -n "${1:-}" ] && { soak_args+=(--map "$1"); shift; }
        [ -n "${1:-}" ] && { soak_args+=(--minutes "$1"); shift; }
        mkdir -p .godot/test-logs
        timeout "$TIMEOUT" "$GODOT" --headless --path . res://tools/soak.tscn -- "${soak_args[@]}" "$@" \
            2>&1 | tee .godot/test-logs/soak.log | grep -E '^SOAK|^soak|^TRACE|SCRIPT ERROR|Parse Error|ERROR|FAIL'
        exit "${PIPESTATUS[0]}"
        ;;
    netchaos)
        [ -x tools/netchaos.sh ] || die "$GAME_NAME has no netchaos rig." 2
        exec tools/netchaos.sh "$@"
        ;;
    suites)
        if [ "${1:-}" = "--shards" ]; then
            for s in $SUITES; do
                if [ -n "$(shards_of "$s")" ]; then printf '%s\n' $(for sh in $(shards_of "$s"); do echo "$s.$sh"; done); else echo "$s"; fi
            done
            exit 0
        fi
        printf '%s\n' $SUITES
        ;;
    perf)
        [ -x tools/perf_budget.sh ] || die "$GAME_NAME has no perf budget." 2
        exec tools/perf_budget.sh "$@"
        ;;
    visual)
        [ -x tools/visual_check.sh ] || die "$GAME_NAME has no visual check." 2
        exec tools/visual_check.sh "$@"
        ;;
    shot)
        for tool in tools/shot.sh tools/screenshot.sh; do
            [ -x "$tool" ] || continue
            if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
                # The tool's own header comment is its usage.
                sed -n '2,/^[^#]/p' "$tool" | sed '$d' | sed 's/^# \{0,1\}//'
                exit 0
            fi
            exec "$tool" "$@"
        done
        die "$GAME_NAME has no screenshot tool." 2
        ;;
    *)
        usage
        exit 2
        ;;
esac; exit $?  # parsed with the case: bash re-reads the file after a long run, and an edited game.sh gave "unexpected EOF"
