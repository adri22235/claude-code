#!/usr/bin/env bash
# Regression tests for plugins/ralph-wiggum/hooks/stop-hook.sh and the
# max-iterations parsing in scripts/setup-ralph-loop.sh.
#
# Covers anthropics/claude-code issues:
#   #95102 the jq parse-failure handler (and the "state file corrupted"
#          handlers) were unreachable under `set -euo pipefail`, so the hook
#          aborted and left a stale state file behind
#   #81826 --max-iterations with a leading zero was read as octal, so 08
#          silently made the loop unbounded and 010 stopped it at 8
#   #81827 a bare message equal to the promise ended the loop although it had
#          no <promise> tag (perl -p printed the unmatched input)
#   #81828 the expected completion promise was not whitespace-normalized, so
#          a promise with doubled or surrounding spaces could never match
#   #81829 "iteration:N" (no space) was readable but not writable, so the
#          counter froze and max_iterations was never reached
# Also: setup-ralph-loop.sh stores the promise as a JSON string, so a promise
# containing " or \ must be decoded by the hook to ever match.
#
# Each test builds a throwaway project dir with a state file and a one-line
# JSONL transcript, pipes Stop-hook input into the real stop-hook.sh, and
# asserts on the exit code, the output and the state file left behind.
# Needs bash, jq and perl, like the hook itself.
#
# Usage: bash plugins/ralph-wiggum/tests/test-stop-hook.sh
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SELF_DIR/../hooks/stop-hook.sh"
SETUP="$SELF_DIR/../scripts/setup-ralph-loop.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
DIR=""
RC=0
OUT=""
ERR=""

# new_project — fresh project dir in $DIR with an empty .claude/
new_project() {
    DIR="$(mktemp -d "$WORK/p.XXXXXX")"
    mkdir -p "$DIR/.claude"
}

# write_state <frontmatter> [prompt] — write the loop state file; <frontmatter>
# is the text between the two --- lines
write_state() {
    printf -- '---\n%s\n---\n\n%s\n' "$1" "${2:-do the task}" > "$DIR/.claude/ralph-loop.local.md"
}

# assistant_says <text> — one-line transcript whose last assistant message is <text>
assistant_says() {
    jq -cn --arg t "$1" \
        '{type: "assistant", message: {role: "assistant", content: [{type: "text", text: $t}]}}' \
        > "$DIR/t.jsonl"
}

# run_hook — run stop-hook.sh from $DIR; sets RC, OUT, ERR
run_hook() {
    (cd "$DIR" && printf '{"session_id": "s1", "transcript_path": "%s", "stop_hook_active": false}' "$DIR/t.jsonl" \
        | bash "$HOOK" > "$DIR/out" 2> "$DIR/err")
    RC=$?
    OUT="$(cat "$DIR/out")"
    ERR="$(cat "$DIR/err")"
}

# run_setup <raw argument text> — run setup-ralph-loop.sh from $DIR the way
# ralph-loop.md does (raw text on stdin); sets RC, OUT, ERR
run_setup() {
    (cd "$DIR" && printf '%s\n' "$1" | bash "$SETUP" > "$DIR/out" 2> "$DIR/err")
    RC=$?
    OUT="$(cat "$DIR/out")"
    ERR="$(cat "$DIR/err")"
}

state_exists() { [ -f "$DIR/.claude/ralph-loop.local.md" ]; }

# field <name> — value of <name> in the state file's leading frontmatter
field() {
    awk '/^---$/{c++; if (c == 2) exit; next} c == 1' "$DIR/.claude/ralph-loop.local.md" \
        | grep "^$1:" | sed "s/^$1: *//"
}

# stopped — the hook ended the loop cleanly
stopped() { [ "$RC" -eq 0 ] && ! state_exists; }

# continued_to <n> — the hook blocked the stop and advanced the counter to <n>
continued_to() {
    [ "$RC" -eq 0 ] && state_exists && [ "$(field iteration)" = "$1" ] \
        && printf '%s' "$OUT" | jq -e '.decision == "block"' > /dev/null 2>&1
}

check() {
    local desc=$1
    shift
    if "$@"; then
        pass=$((pass + 1))
        echo "ok   - $desc"
    else
        fail=$((fail + 1))
        echo "FAIL - $desc"
        echo "       rc=$RC"
        [ -n "$OUT" ] && printf '       stdout: %s\n' "$(printf '%s' "$OUT" | head -c 300)"
        [ -n "$ERR" ] && printf '       stderr: %s\n' "$(printf '%s' "$ERR" | head -c 300)"
        if state_exists; then
            printf '       state: iteration=%s max_iterations=%s\n' "$(field iteration)" "$(field max_iterations)"
        fi
    fi
}

contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac }

# --- Controls: the normal loop keeps working -------------------------------

new_project
write_state $'iteration: 1\nmax_iterations: 10\ncompletion_promise: "DONE"' 'Keep improving the test suite.'
assistant_says "still working"
run_hook
check "control: no promise yet -> loop continues to iteration 2" continued_to 2
check "control: the prompt is fed back" \
    contains "$(printf '%s' "$OUT" | jq -r '.reason' 2>/dev/null)" "Keep improving the test suite."

new_project
write_state $'iteration: 1\nmax_iterations: 10\ncompletion_promise: "DONE"'
assistant_says $'All tests pass.\n<promise>DONE</promise>'
run_hook
check "control: tagged promise ends the loop" stopped
check "control: tagged promise is reported" contains "$OUT" "Detected <promise>DONE</promise>"

new_project
write_state $'iteration: 3\nmax_iterations: 3\ncompletion_promise: null'
assistant_says "still working"
run_hook
check "control: max_iterations reached ends the loop" stopped

# --- #95102: handlers must be reachable under set -e -----------------------

new_project
write_state $'iteration: 1\nmax_iterations: 10\ncompletion_promise: "DONE"'
# matches "role":"assistant" but is not valid JSON (truncated mid-write)
printf '%s\n' '{"role":"assistant","message":{"content":[{"type":"text","text":"hi"' > "$DIR/t.jsonl"
run_hook
check "#95102: unparseable transcript line stops the loop (exit 0, state removed)" stopped
check "#95102: unparseable transcript line prints the guidance" \
    contains "$ERR" "Failed to parse assistant message JSON"

new_project
write_state $'iteration: 1\ncompletion_promise: "DONE"'
assistant_says "still working"
run_hook
check "#95102: state file without max_iterations stops cleanly" stopped
check "#95102: missing max_iterations is reported" contains "$ERR" "max_iterations"

new_project
write_state $'max_iterations: 10\ncompletion_promise: "DONE"'
assistant_says "still working"
run_hook
check "#95102: state file without iteration stops cleanly" stopped

new_project
write_state $'iteration: 1\nmax_iterations: 10'
assistant_says "still working"
run_hook
check "#95102: state file without completion_promise still loops" continued_to 2

# --- #81826: leading zeros are decimal, oversized values fail safe ----------

new_project
write_state $'iteration: 8\nmax_iterations: 08\ncompletion_promise: null'
assistant_says "still working"
run_hook
check "#81826: max_iterations 08 stops at iteration 8" stopped
check "#81826: max_iterations 08 is reported as 8" contains "$OUT" "Max iterations (8) reached"

new_project
write_state $'iteration: 9\nmax_iterations: 010\ncompletion_promise: null'
assistant_says "still working"
run_hook
check "#81826: max_iterations 010 does not stop at 9" continued_to 10
run_hook
check "#81826: max_iterations 010 stops at 10" stopped

new_project
write_state $'iteration: 010\nmax_iterations: 20\ncompletion_promise: null'
assistant_says "still working"
run_hook
check "#81826: iteration 010 advances to 11, not 9" continued_to 11

new_project
write_state $'iteration: 1\nmax_iterations: 9223372036854775808\ncompletion_promise: null'
assistant_says "still working"
run_hook
check "#81826: max_iterations beyond 64-bit range stops instead of looping forever" stopped

new_project
run_setup "do the task --max-iterations 08"
check "#81826: setup accepts --max-iterations 08" test "$RC" -eq 0
check "#81826: setup stores --max-iterations 08 as 8" test "$(field max_iterations)" = "8"
check "#81826: setup reports 8, not unlimited" contains "$OUT" "Max iterations: 8"

new_project
run_setup "do the task --max-iterations 00"
check "#81826: setup stores --max-iterations 00 as 0 (unlimited)" test "$(field max_iterations)" = "0"

new_project
run_setup "do the task --max-iterations 9223372036854775808"
check "#81826: setup rejects a value beyond 64-bit range" test "$RC" -ne 0
check "#81826: rejected value creates no state file" eval '! state_exists'

# --- #81827: only a <promise> tag can end the loop -------------------------

new_project
write_state $'iteration: 1\nmax_iterations: 20\ncompletion_promise: "DONE"'
assistant_says "DONE"
run_hook
check "#81827: bare message equal to the promise does not end the loop" continued_to 2

new_project
write_state $'iteration: 1\nmax_iterations: 20\ncompletion_promise: "DONE"'
assistant_says "<promise>DONE"
run_hook
check "#81827: unclosed <promise> tag does not end the loop" continued_to 2

# --- #81828: expected promise is whitespace-normalized like the observed one

new_project
write_state $'iteration: 1\nmax_iterations: 20\ncompletion_promise: "ALL  DONE"'
assistant_says "<promise>ALL  DONE</promise>"
run_hook
check "#81828: promise with a double space can end the loop" stopped

new_project
write_state $'iteration: 1\nmax_iterations: 20\ncompletion_promise: " DONE "'
assistant_says "<promise>DONE</promise>"
run_hook
check "#81828: promise with surrounding spaces can end the loop" stopped

new_project
write_state $'iteration: 1\nmax_iterations: 20\ncompletion_promise: "ALL DONE"'
assistant_says "<promise>ALL DONE TODAY</promise>"
run_hook
check "#81828: a different promise still does not match" continued_to 2

new_project
write_state $'iteration: 1\nmax_iterations: 20\ncompletion_promise: "DONE*"'
assistant_says "<promise>DONEXYZ</promise>"
run_hook
check "#81828: the comparison stays literal (no glob matching)" continued_to 2

# Promise written by setup-ralph-loop.sh: stored as a JSON string, so " and \
# are escaped in the state file and must be decoded before comparing.
new_project
run_setup "do the task --completion-promise 'say \"done\" \\o/'"
check "setup accepts a promise with quotes and a backslash" test "$RC" -eq 0
assistant_says '<promise>say "done" \o/</promise>'
run_hook
check "promise with quotes and a backslash written by setup can end the loop" stopped

# --- #81829: reader and writer agree on the iteration field ----------------

new_project
write_state $'iteration:1\nmax_iterations: 3\ncompletion_promise: null'
assistant_says "still working"
run_hook
check "#81829: iteration:1 (no space) advances to 2" continued_to 2
run_hook
check "#81829: and on to 3" continued_to 3
run_hook
check "#81829: and max_iterations 3 is reached" stopped

new_project
write_state $'iteration: 1\nmax_iterations: 10\ncompletion_promise: null' $'Step list:\niteration: keep this line\n---\niteration: 99\n---\nend'
assistant_says "still working"
run_hook
check "only the frontmatter counter is read and advanced" continued_to 2
check "iteration: lines in the prompt are left untouched" \
    test "$(grep -c '^iteration: keep this line$' "$DIR/.claude/ralph-loop.local.md")" = "1"
check "iteration: lines after a --- in the prompt are left untouched" \
    test "$(grep -c '^iteration: 99$' "$DIR/.claude/ralph-loop.local.md")" = "1"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
