#!/usr/bin/env python3
"""Stop hook executor for hookify plugin.

This script is called by Claude Code when agent wants to stop.
It reads .claude/hookify.*.local.md files and evaluates stop rules.
"""

import importlib.machinery
import importlib.util
import json
import os
import sys

# CRITICAL: Make the plugin importable as the "hookify" package.
# The imports below use that name, but the directory the plugin is installed in
# need not be called "hookify" (the plugin cache names it by version), so a
# sys.path entry for its parent is not enough. Register the plugin root as the
# package's search path instead.
PLUGIN_ROOT = os.environ.get('CLAUDE_PLUGIN_ROOT') or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))
)
if 'hookify' not in sys.modules:
    _spec = importlib.machinery.ModuleSpec('hookify', None, is_package=True)
    _spec.submodule_search_locations = [PLUGIN_ROOT]
    sys.modules['hookify'] = importlib.util.module_from_spec(_spec)

# Also add PLUGIN_ROOT itself in case we have other scripts
if PLUGIN_ROOT not in sys.path:
    sys.path.insert(0, PLUGIN_ROOT)

try:
    from hookify.core.config_loader import load_rules
    from hookify.core.rule_engine import RuleEngine
except ImportError as e:
    error_msg = {"systemMessage": f"Hookify import error: {e}"}
    print(json.dumps(error_msg), file=sys.stdout)
    sys.exit(0)


def main():
    """Main entry point for Stop hook."""
    try:
        # Read input from stdin
        input_data = json.load(sys.stdin)

        # Load stop rules
        rules = load_rules(event='stop')

        # Evaluate rules
        engine = RuleEngine()
        result = engine.evaluate_rules(rules, input_data)

        # Always output JSON (even if empty)
        print(json.dumps(result), file=sys.stdout)

    except Exception as e:
        # On any error, allow the operation
        error_output = {
            "systemMessage": f"Hookify error: {str(e)}"
        }
        print(json.dumps(error_output), file=sys.stdout)

    finally:
        # ALWAYS exit 0
        sys.exit(0)


if __name__ == '__main__':
    main()
