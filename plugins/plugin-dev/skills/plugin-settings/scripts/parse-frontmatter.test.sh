#!/bin/bash
# Regression tests for parse-frontmatter.sh: only the leading frontmatter block
# is read, so a `---` line in the body (a horizontal rule) must not reopen it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER="$SCRIPT_DIR/parse-frontmatter.sh"
TMP_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT

failures=0

check() {
  local label="$1" expected_rc="$2" expected_out="$3"
  shift 3
  local out rc=0
  out="$(bash "$PARSER" "$@" 2>/dev/null)" || rc=$?
  if [ "$rc" -eq "$expected_rc" ] && [ "$out" = "$expected_out" ]; then
    echo "PASS: $label"
  else
    echo "FAIL: $label (rc=$rc, want $expected_rc)"
    echo "  got:  $(printf '%s' "$out" | head -5 | tr '\n' '|')"
    echo "  want: $(printf '%s' "$expected_out" | head -5 | tr '\n' '|')"
    failures=$((failures + 1))
  fi
}

printf -- '---\nenabled: true\nmode: strict\n---\n\nSome text.\n\n---\n\nmode: loose\nnote: later\n' > "$TMP_DIR/rule.md"

check "frontmatter stops at the closing delimiter" 0 $'enabled: true\nmode: strict' "$TMP_DIR/rule.md"
check "field is read from the frontmatter, not the body" 0 "strict" "$TMP_DIR/rule.md" mode
check "a field that only the body has is not found" 1 "" "$TMP_DIR/rule.md" note

printf -- '---\r\nenabled: true\r\n---\r\nBody\r\n---\r\nmore: stuff\r\n' > "$TMP_DIR/crlf.md"
check "CRLF line endings" 0 "enabled: true" "$TMP_DIR/crlf.md"

printf -- 'No frontmatter here\n\n---\nlooks: like it\n---\n' > "$TMP_DIR/none.md"
check "a --- block that is not at the top is not frontmatter" 1 "" "$TMP_DIR/none.md"

printf -- '---\nenabled: true\n---\n' > "$TMP_DIR/plain.md"
check "plain frontmatter still works" 0 "true" "$TMP_DIR/plain.md" enabled

echo ""
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "All tests passed"
