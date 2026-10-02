#!/usr/bin/env bash
# Find a working Python 3 interpreter and exec the hook with it.
#
# On Windows + Git Bash, `python3` typically resolves to the Microsoft Store
# stub at C:\Users\<user>\AppData\Local\Microsoft\WindowsApps\python3, which
# exits 49 silently in non-TTY subprocess context (a known Microsoft Store
# stub behavior). This shim
# probes each candidate with `-c ""` and skips any that fails, so the Store
# stub falls through to the real python.org install (`python` in Git Bash) or
# the `py -3` launcher.
#
# Order:
#   1. python3   — canonical on macOS/Linux; the Store stub fails the probe.
#   2. python    — python.org installs on Windows; some Linux distros (RHEL 7
#                  EOL'd 2024-06) point this at Python 2, but `-c ""` succeeds
#                  on Python 2 too — guard with a version check.
#   3. py -3     — Windows Python launcher.
#
# Args after the shim path are passed straight through to the chosen
# interpreter, so the hooks.json invocation is:
#   bash "${CLAUDE_PLUGIN_ROOT}/hooks/sg-python.sh" \
#        "${CLAUDE_PLUGIN_ROOT}/hooks/security_reminder_hook.py"
set -e

# Fast path: reuse the candidate a previous run already probed. Every probe is
# an extra interpreter launch, and on Windows the Python Install Manager
# aliases (py, python, python3 under WindowsApps) start an AppX update per
# activation that leaks memory in AppXSvc, so probing and then exec'ing doubles
# that cost on every hook (anthropics/claude-code#98929). Only the candidate
# *name* is cached, and only if it is one of the fixed names below, so the
# file's contents are never run as-is. The entry expires after a day, and is
# ignored when the command is no longer on PATH, so a changed or removed
# interpreter falls back to probing.
cache_file="${SG_PYTHON_CACHE:-${HOME:+$HOME/.claude/security/python-cmd}}"
if [ -n "$cache_file" ] && [ -f "$cache_file" ] \
        && [ -n "$(find "$cache_file" -mmin -1440 2>/dev/null)" ]; then
    cached=$(head -n 1 "$cache_file" 2>/dev/null || true)
    case "$cached" in
        "python3"|"python"|"py -3")
            if command -v "${cached%% *}" >/dev/null 2>&1; then
                # shellcheck disable=SC2086
                exec $cached "$@"
            fi
            ;;
    esac
fi

# Capture probe stderr so the all-candidates-failed path can report useful
# diagnostics. Logging is best-effort: if the temp file cannot be created,
# fall back to the previous stderr-suppression behavior.
errlog=""
errlog=$(mktemp 2>/dev/null) || true
if [ -n "$errlog" ]; then
    trap 'rm -f "$errlog"' EXIT
fi

probe() {
    # $1..N: the interpreter command (may be multi-word like `py -3`)
    # Probe writes the major version to stdout and exits 0 iff it's >=3.
    if [ -n "$errlog" ]; then
        "$@" -c 'import sys; print(sys.version_info[0])' 2>>"$errlog"
    else
        "$@" -c 'import sys; print(sys.version_info[0])' 2>/dev/null
    fi
}

for cmd in "python3" "python" "py -3"; do
    # Word-split intentionally so `py -3` works
    # shellcheck disable=SC2086
    v=$(probe $cmd) || continue
    if [ "$v" = "3" ]; then
        if [ -n "$errlog" ]; then
            rm -f "$errlog"
        fi
        # Best-effort: write via a temp name so concurrent hooks never read a
        # half-written file, and never let a cache failure block the hook.
        if [ -n "$cache_file" ]; then
            { mkdir -p "$(dirname "$cache_file")" \
                && printf '%s\n' "$cmd" > "$cache_file.$$" \
                && mv -f "$cache_file.$$" "$cache_file"; } 2>/dev/null \
                || rm -f "$cache_file.$$" 2>/dev/null || true
        fi
        # shellcheck disable=SC2086
        exec $cmd "$@"
    fi
done

echo "security-guidance: no working Python 3 interpreter found." >&2
echo "  tried: python3, python, py -3" >&2
if [ -n "$errlog" ] && [ -s "$errlog" ]; then
    echo "  probe errors:" >&2
    sed 's/^/    /' "$errlog" >&2
fi
echo "  on Windows, install Python from https://python.org (NOT the Microsoft Store)" >&2
exit 1
