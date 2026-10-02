#!/bin/bash

# Ralph Wiggum Stop Hook
# Prevents session exit when a ralph-loop is active
# Feeds Claude's output back as input to continue the loop

set -euo pipefail

# Read hook input from stdin (advanced stop hook API)
HOOK_INPUT=$(cat)

# Check if ralph-loop is active
RALPH_STATE_FILE=".claude/ralph-loop.local.md"

if [[ ! -f "$RALPH_STATE_FILE" ]]; then
  # No active loop - allow exit
  exit 0
fi

# Parse the leading markdown frontmatter (YAML between the first two ---
# lines) and extract values. Only that block counts: the prompt below it may
# contain --- lines of its own. The `|| true`s keep a missing field from
# aborting the script under `set -e -o pipefail`, which would leave the state
# file behind; the validation below stops the loop cleanly instead.
FRONTMATTER=$(awk '/^---$/{c++; if (c == 2) exit; next} c == 1' "$RALPH_STATE_FILE")
ITERATION=$(echo "$FRONTMATTER" | grep '^iteration:' | sed 's/^iteration: *//' || true)
MAX_ITERATIONS=$(echo "$FRONTMATTER" | grep '^max_iterations:' | sed 's/^max_iterations: *//' || true)
COMPLETION_PROMISE_RAW=$(echo "$FRONTMATTER" | grep '^completion_promise:' | sed 's/^completion_promise: *//' || true)

# setup-ralph-loop.sh writes the promise as a JSON string, so a promise
# containing " or \ is stored escaped. Decode it; if that fails (e.g. a
# hand-written state file), just strip the surrounding quotes.
if [[ "$COMPLETION_PROMISE_RAW" == \"*\" ]]; then
  COMPLETION_PROMISE=$(printf '%s' "$COMPLETION_PROMISE_RAW" | jq -r '.' 2>/dev/null) \
    || COMPLETION_PROMISE=$(printf '%s' "$COMPLETION_PROMISE_RAW" | sed 's/^"\(.*\)"$/\1/')
else
  COMPLETION_PROMISE="$COMPLETION_PROMISE_RAW"
fi

# Print a non-negative decimal integer in canonical form, or fail.
# Leading zeros mean decimal: bash arithmetic would read 08 as an invalid
# octal number (silently skipping the max_iterations check) and 010 as 8.
# More than 18 digits could overflow bash's 64-bit arithmetic and turn into a
# different (even negative, i.e. unlimited) number, so that fails too.
to_decimal() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  value="${value#"${value%%[!0]*}"}"
  value="${value:-0}"
  [[ ${#value} -le 18 ]] || return 1
  echo "$value"
}

# Validate numeric fields before arithmetic operations
if ! ITERATION_DECIMAL=$(to_decimal "$ITERATION"); then
  echo "⚠️  Ralph loop: State file corrupted" >&2
  echo "   File: $RALPH_STATE_FILE" >&2
  echo "   Problem: 'iteration' field is not a valid number (got: '$ITERATION')" >&2
  echo "" >&2
  echo "   This usually means the state file was manually edited or corrupted." >&2
  echo "   Ralph loop is stopping. Run /ralph-loop again to start fresh." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi
ITERATION="$ITERATION_DECIMAL"

if ! MAX_ITERATIONS_DECIMAL=$(to_decimal "$MAX_ITERATIONS"); then
  echo "⚠️  Ralph loop: State file corrupted" >&2
  echo "   File: $RALPH_STATE_FILE" >&2
  echo "   Problem: 'max_iterations' field is not a valid number (got: '$MAX_ITERATIONS')" >&2
  echo "" >&2
  echo "   This usually means the state file was manually edited or corrupted." >&2
  echo "   Ralph loop is stopping. Run /ralph-loop again to start fresh." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi
MAX_ITERATIONS="$MAX_ITERATIONS_DECIMAL"

# Check if max iterations reached
if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
  echo "🛑 Ralph loop: Max iterations ($MAX_ITERATIONS) reached."
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Get transcript path from hook input
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path')

if [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  echo "⚠️  Ralph loop: Transcript file not found" >&2
  echo "   Expected: $TRANSCRIPT_PATH" >&2
  echo "   This is unusual and may indicate a Claude Code internal issue." >&2
  echo "   Ralph loop is stopping." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Read last assistant message from transcript (JSONL format - one JSON per line)
# First check if there are any assistant messages
if ! grep -q '"role":"assistant"' "$TRANSCRIPT_PATH"; then
  echo "⚠️  Ralph loop: No assistant messages found in transcript" >&2
  echo "   Transcript: $TRANSCRIPT_PATH" >&2
  echo "   This is unusual and may indicate a transcript format issue" >&2
  echo "   Ralph loop is stopping." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Extract last assistant message with explicit error handling
LAST_LINE=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -1)
if [[ -z "$LAST_LINE" ]]; then
  echo "⚠️  Ralph loop: Failed to extract last assistant message" >&2
  echo "   Ralph loop is stopping." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Parse JSON with error handling. Test the assignment itself: under `set -e`
# a failing command substitution aborts the script right here, so a separate
# `$?` check afterwards never ran and the state file was left behind.
if ! LAST_OUTPUT=$(echo "$LAST_LINE" | jq -r '
  .message.content |
  map(select(.type == "text")) |
  map(.text) |
  join("\n")
' 2>&1); then
  echo "⚠️  Ralph loop: Failed to parse assistant message JSON" >&2
  echo "   Error: $LAST_OUTPUT" >&2
  echo "   This may indicate a transcript format issue" >&2
  echo "   Ralph loop is stopping." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

if [[ -z "$LAST_OUTPUT" ]]; then
  echo "⚠️  Ralph loop: Assistant message contained no text content" >&2
  echo "   Ralph loop is stopping." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Check for completion promise (only if set)
if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  # Extract the text of the FIRST <promise>...</promise> tag using Perl for
  # multiline support (-0777 slurps the entire input, the s flag makes .
  # match newlines, .*? is non-greedy) and normalize its whitespace.
  # -n prints only when a tag is found: with -p, a message without any tag
  # was echoed back whole, so a bare message equal to the promise ended the
  # loop.
  PROMISE_TEXT=$(printf '%s' "$LAST_OUTPUT" | perl -0777 -ne 'if (/<promise>(.*?)<\/promise>/s) { my $t = $1; $t =~ s/^\s+|\s+$//g; $t =~ s/\s+/ /g; print $t; }' 2>/dev/null || echo "")

  # Normalize the expected promise the same way, so a promise with doubled or
  # surrounding whitespace can still be matched.
  EXPECTED_PROMISE=$(printf '%s' "$COMPLETION_PROMISE" | perl -0777 -pe 's/^\s+|\s+$//g; s/\s+/ /g' 2>/dev/null || echo "")

  # Literal string comparison: the right-hand side is quoted, so [[ ]] does
  # not treat *, ? or [ in the promise as glob pattern characters.
  if [[ -n "$PROMISE_TEXT" ]] && [[ "$PROMISE_TEXT" = "$EXPECTED_PROMISE" ]]; then
    echo "✅ Ralph loop: Detected <promise>$COMPLETION_PROMISE</promise>"
    rm "$RALPH_STATE_FILE"
    exit 0
  fi
fi

# Not complete - continue loop with SAME PROMPT
NEXT_ITERATION=$((ITERATION + 1))

# Extract prompt (everything after the closing ---)
# Skip first --- line, skip until second --- line, then print everything after
# Use i>=2 instead of i==2 to handle --- in prompt content
PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$RALPH_STATE_FILE")

if [[ -z "$PROMPT_TEXT" ]]; then
  echo "⚠️  Ralph loop: State file corrupted or incomplete" >&2
  echo "   File: $RALPH_STATE_FILE" >&2
  echo "   Problem: No prompt text found" >&2
  echo "" >&2
  echo "   This usually means:" >&2
  echo "     • State file was manually edited" >&2
  echo "     • File was corrupted during writing" >&2
  echo "" >&2
  echo "   Ralph loop is stopping. Run /ralph-loop again to start fresh." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Update iteration in the leading frontmatter only, accepting "iteration:N"
# as well as "iteration: N" like the reader above; otherwise the counter
# never advances and max_iterations is never reached. Lines in the prompt are
# left alone. Portable across macOS and Linux: create a temp file, then
# atomically replace.
TEMP_FILE="${RALPH_STATE_FILE}.tmp.$$"
awk -v n="$NEXT_ITERATION" '
  /^---$/ && c < 2 { c++; print; next }
  c == 1 && /^iteration:/ { print "iteration: " n; next }
  { print }
' "$RALPH_STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$RALPH_STATE_FILE"

# Build system message with iteration count and completion promise info
if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  SYSTEM_MSG="🔄 Ralph iteration $NEXT_ITERATION | To stop: output <promise>$COMPLETION_PROMISE</promise> (ONLY when statement is TRUE - do not lie to exit!)"
else
  SYSTEM_MSG="🔄 Ralph iteration $NEXT_ITERATION | No completion promise set - loop runs infinitely"
fi

# Output JSON to block the stop and feed prompt back
# The "reason" field contains the prompt that will be sent back to Claude
jq -n \
  --arg prompt "$PROMPT_TEXT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'

# Exit 0 for successful hook execution
exit 0
