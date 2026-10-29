#!/bin/bash
# Runs one chat measurement in Biscotti Dev with nobody at the Mac (README.md,
# "Run one measurement by hand", steps 2 to 10):
#
#   Tools/chat_bench/run.sh RUN PLAN
#
# RUN names the result files (results/RUN.ndjson, .json and .md). PLAN is a
# plan's name (plans/PLAN.json) or a path to one. The plan needs a "record"
# block, so that the app records by itself, and normally a "model".
#
# It plays the fixture through the speakers at the current volume and output.
# Run it outside the agent sandbox: `log stream` does not run inside it. The
# app is the one `make build-development` builds, in BISCOTTI_DEV_DERIVED_DATA
# when set; BISCOTTI_DEV_APP overrides its path.
# Exit status: 0 analyzed, 1 cannot start, 2 the run was aborted, 3 the
# analysis failed.
set -euo pipefail

BENCH=$(cd "$(dirname "$0")" && pwd)
DERIVED_DATA=${BISCOTTI_DEV_DERIVED_DATA:-/Volumes/Data/projects/Developer/biscotti/DerivedData/Development}
APP=${BISCOTTI_DEV_APP:-"$DERIVED_DATA/Build/Products/Debug/Biscotti Dev.app"}
FIXTURE=${CHAT_BENCH_FIXTURE:-/Volumes/Data/projects/Developer/biscotti/live_bench/fixtures/soak/mixed.wav}
# Processes inside the app bundle (the app and its workers). The capture's own
# predicate names "Biscotti Dev.app" too, so the pattern needs "/Contents/".
DEV_PROCESSES='Biscotti Dev\.app/Contents/'
PRODUCTION_PROCESSES='/Applications/Biscotti\.app/Contents/'
LAUNCH_LIMIT=$((20 * 60)) # from the app's start to the plan line: launch and speech model compiles
START_LIMIT=90            # from the plan line to recording-started
RUN_LIMIT=$((35 * 60))    # from the plan line to plan-done
AFTER_DONE=60          # after plan-done: the live session's summary line

usage() {
    echo "Usage: $0 RUN PLAN (PLAN: a name in plans/, or a path)" >&2
    exit 1
}

say() { echo "$(date '+%H:%M:%S') $*"; }

[[ $# -eq 2 ]] || usage
RUN=$1
if [[ -f $2 ]]; then
    PLAN=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
elif [[ -f $BENCH/plans/$2.json ]]; then
    PLAN=$BENCH/plans/$2.json
else
    echo "No plan named or at '$2'." >&2
    usage
fi
grep -q '"record"' "$PLAN" || { echo "$PLAN has no \"record\" block: follow README.md to record by hand." >&2; exit 1; }
[[ -d $APP ]] || { echo "No Biscotti Dev at $APP: build it with 'make build-development'." >&2; exit 1; }
[[ -f $FIXTURE ]] || { echo "No fixture at $FIXTURE." >&2; exit 1; }

RESULTS=$BENCH/results
CAPTURE=$RESULTS/$RUN.ndjson
# The capture is the only copy of a run's raw lines, and git ignores it.
[[ -e $CAPTURE ]] && { echo "$CAPTURE exists: move it before running '$RUN' again." >&2; exit 1; }
log_pid=
afplay_pid=

dev_running() { pgrep -f "$DEV_PROCESSES" >/dev/null; }
production_running() { pgrep -f "$PRODUCTION_PROCESSES" >/dev/null; }
captured() { grep -q -- "$1" "$CAPTURE" 2>/dev/null; }

# Quits Biscotti Dev, never production Biscotti, and waits for its workers too.
# The quit goes again every 5 s: each one reaches one copy, and two builds of
# Biscotti Dev can run at once.
quit_dev() {
    local second
    for second in $(seq 0 59); do
        dev_running || return 0
        if ((second % 5 == 0)); then osascript -e 'quit app "Biscotti Dev"' >/dev/null 2>&1 || true; fi
        sleep 1
    done
    say "Biscotti Dev is still running after 60 s:"
    pgrep -fl "$DEV_PROCESSES" || true
    return 1
}

stop_playback() {
    if [[ -n $afplay_pid ]]; then
        kill "$afplay_pid" 2>/dev/null || true
        wait "$afplay_pid" 2>/dev/null || true
        afplay_pid=
    fi
}

stop_capture() {
    if [[ -n $log_pid ]]; then
        kill -INT "$log_pid" 2>/dev/null || true
        wait "$log_pid" 2>/dev/null || true
        log_pid=
    fi
}

cleanup() {
    stop_playback
    stop_capture
    quit_dev || true
}
trap cleanup EXIT
trap 'exit 2' INT TERM

abort() {
    say "Aborted: $*"
    say "The capture is $CAPTURE."
    exit 2
}

# Fails the run if the driver gave up, the app quit, or production Biscotti started.
check_run() {
    if captured 'abort reason='; then
        abort "the driver could not run the plan: $(grep -o 'abort reason=[A-Za-z]*' "$CAPTURE" | head -1)"
    fi
    dev_running || abort "Biscotti Dev quit."
    if production_running; then
        abort "production Biscotti is running: quit it yourself, then run again."
    fi
}

# Step 2: no other copy, and production Biscotti left alone.
if production_running; then
    echo "Production Biscotti is running. This script never touches it: quit it yourself, then run again." >&2
    exit 1
fi
if dev_running; then
    say "Quitting the Biscotti Dev that is running."
    quit_dev || { echo "Could not quit Biscotti Dev." >&2; exit 1; }
fi

# Step 3: the capture starts before the app.
mkdir -p "$RESULTS"
/usr/bin/log stream --style ndjson --level info \
    --predicate 'subsystem == "net.scosman.biscotti" AND processImagePath CONTAINS "Biscotti Dev.app"' \
    >"$CAPTURE" &
log_pid=$!
sleep 2
kill -0 "$log_pid" 2>/dev/null || { log_pid=; echo "log stream did not start (run this outside the agent sandbox)." >&2; exit 1; }

# Step 4: the app, with the plan's absolute path.
say "Starting Biscotti Dev with $PLAN."
open "$APP" --args -chatLoadTest "$PLAN"
started=$SECONDS

# The driver writes its worker lines as soon as it starts. Without them, the
# app started without the plan: another copy was starting or running.
until captured 'worker name='; do
    if ((SECONDS - started > 30)); then
        abort "Biscotti Dev started without the plan (no driver lines within 30 s): was another copy starting?"
    fi
    sleep 1
done

# The driver writes its plan line once the app's launch is done and no speech
# model is being prepared (a new build or a purged Core ML cache compiles them).
until captured 'plan name='; do
    if ((SECONDS - started > LAUNCH_LIMIT)); then
        abort "no plan line within $((LAUNCH_LIMIT / 60)) minutes: the app's launch or its model preparation did not end."
    fi
    sleep 2
    # The app needs a moment to start.
    if ((SECONDS - started > 10)); then check_run; fi
done
# A driver without recording control (an older build) writes no record=.
grep -q 'plan name=.* record=' "$CAPTURE" || abort "the app's driver cannot record (no record= in its plan line): build Biscotti Dev from this branch."
say "Launch done after $((SECONDS - started)) s: $(grep -o 'model=[^ ]*' "$CAPTURE" | head -1), $(grep -o 'live=[a-z]*' "$CAPTURE" | head -1)."
started=$SECONDS

# Step 5: the driver starts the recording itself.
until captured 'recording-started'; do
    check_run
    if ((SECONDS - started > START_LIMIT)); then
        abort "no recording started within $START_LIMIT s. A permission prompt may be waiting (this script answers none), or the recording failed."
    fi
    sleep 1
done
say "Recording started. Playing $(basename "$FIXTURE")."

# Step 6: the fixture from its start.
afplay "$FIXTURE" &
afplay_pid=$!

# Steps 7 and 8: the driver stops the recording; plan-done comes after Stop and the questions.
until captured 'plan-done'; do
    if ((SECONDS - started > RUN_LIMIT)); then
        abort "no plan-done within $((RUN_LIMIT / 60)) minutes of the plan line."
    fi
    check_run
    sleep 5
done
say "Plan done. Waiting $AFTER_DONE s for the live session's summary."
sleep "$AFTER_DONE"

# Step 9.
stop_playback
stop_capture
quit_dev || say "Warning: Biscotti Dev did not quit."

# Step 10.
say "Analyzing."
uv run "$BENCH/analyze.py" "$RUN" --log "$CAPTURE" || exit 3
