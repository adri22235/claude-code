"""Regression tests for the hookify plugin.

Run from anywhere:

    python3 -m unittest discover -s plugins/hookify/tests -p 'test_*.py'

The subprocess tests drive the real hook scripts with a rule file in a scratch
project, so they cover how Claude Code runs them: a plugin directory that is
not named "hookify", a path with a space in it, and a non-UTF-8 default
encoding.
"""

import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PLUGIN_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PLUGIN_ROOT.parent))

from hookify.core.config_loader import extract_frontmatter, load_rule_file  # noqa: E402


class ExtractFrontmatterTests(unittest.TestCase):
    def test_value_containing_triple_dash_is_kept_whole(self):
        content = "---\nname: dashes\nevent: bash\npattern: foo---bar\n---\nBody\n"
        frontmatter, message = extract_frontmatter(content)
        self.assertEqual(frontmatter["pattern"], "foo---bar")
        self.assertEqual(message, "Body")

    def test_triple_dash_in_the_body_stays_in_the_message(self):
        content = "---\nname: n\nevent: bash\n---\nAbove\n\n---\n\nBelow\n"
        frontmatter, message = extract_frontmatter(content)
        self.assertEqual(frontmatter["name"], "n")
        self.assertEqual(message, "Above\n\n---\n\nBelow")

    def test_closing_delimiter_must_be_a_line_of_its_own(self):
        content = "---\nname: n\npattern: a\n---b\n---\nBody\n"
        frontmatter, message = extract_frontmatter(content)
        self.assertEqual(frontmatter["name"], "n")
        self.assertEqual(frontmatter["pattern"], "a")
        self.assertEqual(message, "Body")

    def test_crlf_line_endings(self):
        content = "---\r\nname: n\r\nevent: bash\r\n---\r\nBody\r\n"
        frontmatter, message = extract_frontmatter(content)
        self.assertEqual(frontmatter["name"], "n")
        self.assertEqual(message, "Body")

    def test_empty_frontmatter(self):
        self.assertEqual(extract_frontmatter("---\n---\nBody\n"), ({}, "Body"))

    def test_no_frontmatter_returns_the_content_untouched(self):
        for content in ("Just text\n", "---\nnever closed\n", ""):
            with self.subTest(content=content):
                self.assertEqual(extract_frontmatter(content), ({}, content))


class RuleFileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def write_rule(self, name, text, encoding="utf-8"):
        path = self.tmp / name
        path.write_bytes(text.encode(encoding))
        return path

    def test_rule_with_triple_dash_pattern_loads_intact(self):
        path = self.write_rule(
            "hookify.dashes.local.md",
            "---\nname: dashes\nenabled: true\nevent: bash\npattern: a---b\n---\nMsg\n",
        )
        rule = load_rule_file(str(path))
        self.assertIsNotNone(rule)
        self.assertEqual(rule.pattern, "a---b")
        self.assertEqual(rule.message, "Msg")

    def test_utf8_bom_is_accepted(self):
        path = self.write_rule(
            "hookify.bom.local.md",
            "---\nname: bom\nenabled: true\nevent: bash\npattern: x\n---\nMsg\n",
            encoding="utf-8-sig",
        )
        rule = load_rule_file(str(path))
        self.assertIsNotNone(rule)
        self.assertEqual(rule.name, "bom")

    def test_non_ascii_rule_loads_under_a_non_utf8_default_encoding(self):
        # Windows defaults to cp1252; ASCII is the same failure on Linux.
        path = self.write_rule(
            "hookify.acentos.local.md",
            "---\nname: acentos\nenabled: true\nevent: bash\npattern: rm\n---\n¡Cuidado! ✓\n",
        )
        code = (
            "import sys, locale;"
            f"sys.path.insert(0, {str(PLUGIN_ROOT.parent)!r});"
            "from hookify.core.config_loader import load_rule_file;"
            "assert locale.getpreferredencoding(False).lower() not in ('utf-8', 'utf8'), 'encoding is UTF-8';"
            f"r = load_rule_file({str(path)!r});"
            "assert r is not None, 'rule was skipped';"
            "assert r.message == '\\u00a1Cuidado! \\u2713', ascii(r.message)"
        )
        env = dict(
            os.environ,
            PYTHONUTF8="0",
            PYTHONCOERCECLOCALE="0",
            PYTHONIOENCODING="utf-8",
            LC_ALL="C",
        )
        result = subprocess.run(
            [sys.executable, "-c", code], env=env, capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_bundled_examples_are_named_so_they_load(self):
        examples = sorted((PLUGIN_ROOT / "examples").glob("*.local.md"))
        self.assertTrue(examples)
        for example in examples:
            with self.subTest(example=example.name):
                self.assertTrue(
                    example.name.startswith("hookify."),
                    "only hookify.*.local.md files are loaded",
                )
                self.assertIsNotNone(load_rule_file(str(example)))


class HookScriptTests(unittest.TestCase):
    """Run the hook the way Claude Code does, from an installed copy."""

    RULE = (
        "---\nname: warn-rm\nenabled: true\nevent: bash\npattern: rm -rf\n---\n"
        "RM-WARNING\n"
    )

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.project = self.tmp / "project"
        (self.project / ".claude").mkdir(parents=True)
        (self.project / ".claude" / "hookify.warn-rm.local.md").write_text(self.RULE)

    def install(self, *parts):
        """Copy the plugin to tmp/<parts> and return that directory."""
        dest = self.tmp.joinpath(*parts)
        shutil.copytree(
            PLUGIN_ROOT,
            dest,
            ignore=shutil.ignore_patterns("__pycache__", "tests"),
        )
        return dest

    def run_hook(self, command, root, tool_input=None, set_root_env=True):
        env = {k: v for k, v in os.environ.items() if k != "CLAUDE_PLUGIN_ROOT"}
        if set_root_env:
            env["CLAUDE_PLUGIN_ROOT"] = str(root)
        payload = {
            "tool_name": "Bash",
            "tool_input": tool_input or {"command": "rm -rf /tmp/x"},
            "hook_event_name": "PreToolUse",
        }
        return subprocess.run(
            command,
            shell=isinstance(command, str),
            cwd=self.project,
            env=env,
            input=json.dumps(payload),
            capture_output=True,
            text=True,
        )

    def assert_rule_fired(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("import error", result.stdout.lower(), result.stdout)
        self.assertIn("RM-WARNING", json.loads(result.stdout)["systemMessage"])

    def test_works_when_the_plugin_directory_is_not_named_hookify(self):
        # The plugin cache names the directory by version.
        root = self.install("cache", "hookify", "1.0.0")
        self.assert_rule_fired(
            self.run_hook([sys.executable, str(root / "hooks" / "pretooluse.py")], root)
        )

    def test_works_without_claude_plugin_root_set(self):
        root = self.install("somewhere", "else")
        self.assert_rule_fired(
            self.run_hook(
                [sys.executable, str(root / "hooks" / "pretooluse.py")],
                root,
                set_root_env=False,
            )
        )

    def test_every_hook_script_imports_from_a_renamed_directory(self):
        root = self.install("cache", "hookify", "2.3.4")
        for name in ("pretooluse", "posttooluse", "stop", "userpromptsubmit"):
            with self.subTest(hook=name):
                result = subprocess.run(
                    [sys.executable, str(root / "hooks" / f"{name}.py")],
                    cwd=self.project,
                    env=dict(os.environ, CLAUDE_PLUGIN_ROOT=str(root)),
                    input=json.dumps({"hook_event_name": name}),
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("import error", result.stdout.lower(), result.stdout)

    def test_hooks_json_commands_survive_a_path_with_a_space(self):
        root = self.install("my plugins", "hookify")
        hooks = json.loads((root / "hooks" / "hooks.json").read_text())["hooks"]
        commands = [
            entry["hooks"][0]["command"]
            for entries in hooks.values()
            for entry in entries
        ]
        self.assertEqual(len(commands), 4)
        for command in commands:
            with self.subTest(command=command):
                self.assertIn('"${CLAUDE_PLUGIN_ROOT}', command, "path must be quoted")

        # Run the PreToolUse command through a shell, as the harness does.
        pre = next(c for c in commands if "/hooks/pretooluse.py" in c)
        self.assert_rule_fired(
            self.run_hook(pre.replace("python3", shlex.quote(sys.executable), 1), root)
        )

    def test_missing_hook_script_reports_an_error_instead_of_blocking(self):
        # Exit code 2 from a hook means "block". python3 exits 2 when it cannot
        # open the script, so a plugin directory that moved under a running
        # session (an org plugin re-synced to a new path) would block every
        # prompt and tool call. The commands must exit non-zero but not 2.
        root = self.install("synced", "org", "hookify~g2")
        hooks = json.loads((root / "hooks" / "hooks.json").read_text())["hooks"]
        commands = {event: entries[0]["hooks"][0]["command"] for event, entries in hooks.items()}
        gone = self.tmp / "synced" / "org" / "hookify~g1"  # the path the session still holds
        for event, command in commands.items():
            with self.subTest(event=event):
                result = subprocess.run(
                    command,
                    shell=True,
                    cwd=self.project,
                    env=dict(os.environ, CLAUDE_PLUGIN_ROOT=str(gone)),
                    input=json.dumps({"hook_event_name": event}),
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(result.returncode, 2, "exit 2 would block")
                self.assertNotEqual(result.returncode, 0, "the failure must be visible")
                self.assertIn("hook script not found", result.stderr)


if __name__ == "__main__":
    unittest.main()
