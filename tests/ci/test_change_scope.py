#!/usr/bin/env python3
"""Run in rust.yaml's golden job; stdlib, local Git fixtures, no models/builds."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from change_scope import classify, event_scope


SCRIPT = Path(__file__).with_name("change_scope.py").resolve()


class PolicyTests(unittest.TestCase):
    def test_only_external_documentation_is_not_applicable(self):
        scope = classify(["docs/ci-efficiency.md", "README.md", "HANDOFF.md", "ROADMAP.md"])
        self.assertFalse(scope.full_checks)

    def test_package_fixtures_contracts_and_tooling_always_require_checks(self):
        for path in ("rebirth/README.md", "rebirth/vignettes/intro.qmd",
                     "rebirth/R/llm.R", "rebirth/src/llama.cpp/README.md",
                     "tests/llm-golden/vision/README.md", "tests/data.bin",
                     "API-GRAMMAR.md", "DECISIONS.md", "rust-toolchain.toml",
                     ".github/workflows/R-CMD-check.yaml", "tests/ci/change_scope.py",
                     "tests/ci/test_change_scope.py", "integrations/skills/x/SKILL.md",
                     "new-directory/README.md", "docs/fixture.json", "docs/nested/file.md"):
            with self.subTest(path=path):
                self.assertTrue(classify(["README.md", path]).full_checks)

    def test_empty_and_noncanonical_paths_fail_closed(self):
        self.assertTrue(classify([]).full_checks)
        for path in ("", "/README.md", "../README.md", "docs/../README.md",
                     "docs//file.md", "docs/./file.md", "docs\\file.md",
                     "docs/a\nb.md", "docs/a\x00b.md", "docs/a\x7fb.md", None):
            with self.subTest(path=path):
                self.assertTrue(classify([path]).full_checks)


class GitRangeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "--quiet", "-b", "main")
        self.git("config", "user.name", "CI routing fixture")
        self.git("config", "user.email", "ci@example.invalid")
        self.write("README.md", "Initial documentation\n")
        self.write("rebirth/README.md", "Installed package documentation\n")
        self.base = self.commit()

    def git(self, *args, repo=None):
        return subprocess.run(
            ["git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
             "-C", str(repo or self.repo), *args], check=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        ).stdout.decode().strip()

    def write(self, name, contents="Documentation\n"):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")

    def commit(self):
        self.git("add", "--all")
        self.git("commit", "--quiet", "-m", "Fixture change")
        return self.git("rev-parse", "HEAD")

    def push_scope(self, base=None, head=None, repo=None):
        head = head or self.git("rev-parse", "HEAD", repo=repo)
        return event_scope(repo or self.repo, "push",
                           {"before": base or self.base, "after": head}, head)

    def pr_merge(self, *, product=False, advance_base=False):
        self.git("checkout", "--quiet", "-b", "feature")
        if product:
            self.write("rebirth/R/llm.R", "# Product change\n")
            self.commit()
        self.write("docs/feature.md")
        branch_head = self.commit()
        self.git("checkout", "--quiet", "main")
        if advance_base:
            self.write("rebirth/R/base.R", "# Change already on the base branch\n")
            self.commit()
        base = self.git("rev-parse", "HEAD")
        self.git("merge", "--quiet", "--no-ff", "feature", "-m", "PR merge fixture")
        merge = self.git("rev-parse", "HEAD")
        return {"pull_request": {"base": {"sha": base}, "head": {"sha": branch_head}}}, merge

    def test_push_range_covers_earlier_commits_not_just_head_parent(self):
        self.write("rebirth/R/llm.R", "# Product change\n")
        self.commit()
        self.write("docs/latest.md")
        self.commit()
        scope = self.push_scope()
        self.assertTrue(scope.full_checks)
        self.assertEqual(set(scope.paths), {"rebirth/R/llm.R", "docs/latest.md"})

    def test_multiple_documentation_commits_can_use_short_route(self):
        self.write("docs/one.md")
        self.commit()
        self.write("docs/two.md")
        self.commit()
        scope = self.push_scope()
        self.assertFalse(scope.full_checks)
        self.assertEqual(set(scope.paths), {"docs/one.md", "docs/two.md"})

    def test_pr_merge_range_covers_all_feature_commits(self):
        event, merge = self.pr_merge(product=True)
        scope = event_scope(self.repo, "pull_request", event, merge)
        self.assertTrue(scope.full_checks)
        self.assertEqual(set(scope.paths), {"rebirth/R/llm.R", "docs/feature.md"})

    def test_pr_uses_verified_current_base_not_historical_fork_point(self):
        event, merge = self.pr_merge(advance_base=True)
        scope = event_scope(self.repo, "pull_request", event, merge)
        self.assertFalse(scope.full_checks)
        self.assertEqual(scope.paths, ("docs/feature.md",))
        self.assertEqual(scope.base, event["pull_request"]["base"]["sha"])

    def test_shallow_merge_checkout_depth_two_is_sufficient(self):
        event, merge = self.pr_merge()
        for depth, full in ((2, False), (1, True)):
            with self.subTest(depth=depth):
                shallow = self.root / f"shallow-{depth}"
                self.git("clone", "--quiet", "--no-local", f"--depth={depth}",
                         str(self.repo), str(shallow))
                scope = event_scope(shallow, "pull_request", event, merge)
                self.assertEqual(scope.full_checks, full)

    def test_pr_parent_mismatch_or_nonmerge_checkout_fails_closed(self):
        event, merge = self.pr_merge(advance_base=True)
        wrong_base = json.loads(json.dumps(event))
        wrong_base["pull_request"]["base"]["sha"] = self.base
        wrong_head = json.loads(json.dumps(event))
        wrong_head["pull_request"]["head"]["sha"] = self.base
        for metadata in (wrong_base, wrong_head):
            self.assertTrue(event_scope(self.repo, "pull_request", metadata, merge).full_checks)
        self.git("checkout", "--quiet", "feature")
        self.assertTrue(event_scope(self.repo, "pull_request", event,
                                   event["pull_request"]["head"]["sha"]).full_checks)

    def test_missing_new_branch_empty_and_wrong_checkout_fail_closed(self):
        self.assertTrue(self.push_scope().full_checks)
        self.write("docs/one.md")
        head = self.commit()
        for base in ("0" * 40, "f" * 40, "HEAD^", ""):
            with self.subTest(base=base):
                event = {"before": base, "after": head}
                self.assertTrue(event_scope(self.repo, "push", event, head).full_checks)
        self.assertTrue(event_scope(self.repo, "push",
                                   {"before": self.base, "after": self.base}, head).full_checks)
        self.assertTrue(event_scope(self.repo, "push",
                                   {"before": self.base, "after": head}, self.base).full_checks)
        shallow = self.root / "shallow"
        self.git("clone", "--quiet", "--no-local", "--depth=1", str(self.repo), str(shallow))
        self.assertTrue(self.push_scope(repo=shallow).full_checks)

    def test_rename_out_of_package_keeps_deleted_source_path(self):
        (self.repo / "docs").mkdir()
        self.git("mv", "rebirth/README.md", "docs/moved.md")
        self.commit()
        scope = self.push_scope()
        self.assertTrue(scope.full_checks)
        self.assertEqual(set(scope.paths), {"rebirth/README.md", "docs/moved.md"})

    def test_deletion_and_newline_name_cannot_disappear_from_diff(self):
        (self.repo / "rebirth/README.md").unlink()
        self.write("docs/a\nb.md")
        self.commit()
        self.assertTrue(self.push_scope().full_checks)
        # Check the newline independently: name-only output must stay NUL-delimited.
        self.write("rebirth/README.md", "Installed package documentation\n")
        self.commit()
        self.assertTrue(self.push_scope().full_checks)

    def test_invalid_utf8_filename_fails_closed(self):
        # Git trees can contain byte paths that macOS cannot create on disk.
        blob = self.git("hash-object", "-w", "README.md")
        self.git("update-index", "--add", "--cacheinfo", "100644", blob, b"docs/bad-\xff.md")
        self.git("commit", "--quiet", "-m", "Invalid UTF-8 tree fixture")
        self.assertTrue(self.push_scope().full_checks)

    def test_malformed_and_unsupported_events_fail_closed(self):
        for event in (None, [], {}, {"pull_request": {"base": None}}):
            self.assertTrue(event_scope(self.repo, "pull_request", event, self.base).full_checks)
        self.assertTrue(event_scope(self.repo, "workflow_dispatch", {}, self.base).full_checks)

    def test_cli_emits_explicit_not_applicable_and_full_fallback(self):
        self.write("docs/one.md")
        head = self.commit()
        event_file = self.root / "event.json"
        event_file.write_text(json.dumps({"before": self.base, "after": head}))
        output = self.root / "output"
        summary = self.root / "summary"
        env = dict(os.environ, GITHUB_EVENT_PATH=str(event_file), GITHUB_EVENT_NAME="push",
                   GITHUB_SHA=head, GITHUB_OUTPUT=str(output), GITHUB_STEP_SUMMARY=str(summary))
        result = subprocess.run([sys.executable, str(SCRIPT)], cwd=self.repo, env=env,
                                check=True, capture_output=True, text=True)
        self.assertFalse(json.loads(result.stdout)["full_checks"])
        self.assertEqual(output.read_text(), "full_checks=false\n")
        self.assertIn("not applicable", summary.read_text())
        self.assertIn("not reported as passed", summary.read_text())
        event_file.write_text("not JSON")
        subprocess.run([sys.executable, str(SCRIPT)], cwd=self.repo, env=env,
                       check=True, capture_output=True)
        self.assertTrue(output.read_text().endswith("full_checks=true\n"))


if __name__ == "__main__":
    unittest.main()
