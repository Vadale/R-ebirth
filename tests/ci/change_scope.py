#!/usr/bin/env python3
"""Conservative external-documentation routing for ordinary CI (stdlib only).

Every unknown path or unverifiable comparison requires full checks. PRs compare
the checked-out merge tree with its verified first parent, not just HEAD^ of the
contributor branch. A depth-two checkout suffices for that comparison. Pushes
compare the complete event before/after range; a missing baseline runs in full.
The golden/contract, vendor and supply-chain jobs always execute their gates.
"""

import json
import os
from pathlib import Path
import re
import subprocess
from dataclasses import asdict, dataclass


# This is intentionally not "all Markdown". Package docs and test fixtures can
# affect installed artifacts and executable contracts. New root paths run fully.
EXTERNAL_ROOT_DOCS = {"README.md", "AGENTS.md", "CLAUDE.md", "HANDOFF.md", "ROADMAP.md"}
DOC_PATH = re.compile(r"docs/[A-Za-z0-9][A-Za-z0-9_.-]*\.md\Z")
SHA = re.compile(r"[0-9a-f]{40}\Z")


@dataclass(frozen=True)
class Scope:
    full_checks: bool
    reason: str
    paths: tuple = ()
    base: str = ""
    head: str = ""


def classify(paths):
    """Only a nonempty, entirely allowlisted change can omit native builds."""
    paths = tuple(paths)
    if not paths:
        return Scope(True, "Empty change set; full verification required.")
    for path in paths:
        if (not isinstance(path, str) or not path or "\\" in path
                or any(ord(char) < 32 or ord(char) == 127 for char in path)
                or any(part in {"", ".", ".."} for part in path.split("/"))):
            return Scope(True, "Invalid change path; full verification required.")
        if path not in EXTERNAL_ROOT_DOCS and not DOC_PATH.fullmatch(path):
            return Scope(True, "Change outside the external documentation allowlist.", paths)
    return Scope(False, "External documentation-only change.", paths)


def git(repo, *args):
    # Do not permit local replacement refs or diff drivers to hide changed paths.
    return subprocess.run(
        ["git", "--no-replace-objects", "-C", str(repo), *args],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    ).stdout


def commit(repo, value):
    if not isinstance(value, str) or not SHA.fullmatch(value) or value == "0" * 40:
        raise ValueError("Missing or invalid commit identity")
    resolved = git(repo, "rev-parse", "--verify", value + "^{commit}").decode().strip()
    if resolved != value:
        raise ValueError("Commit identity mismatch")
    return value


def event_scope(repo, event_name, event, expected_head):
    """Resolve only trusted event identities; all uncertainty selects full work."""
    try:
        head = commit(repo, expected_head)
        if git(repo, "rev-parse", "HEAD").decode().strip() != head:
            raise ValueError("Checkout does not match the event commit")
        if event_name == "pull_request":
            base = commit(repo, event["pull_request"]["base"]["sha"])
            branch_head = commit(repo, event["pull_request"]["head"]["sha"])
            parents = git(repo, "rev-list", "--parents", "-n", "1", head).decode().split()
            if parents != [head, base, branch_head]:
                raise ValueError("PR merge parents do not match the event base and head")
        elif event_name == "push":
            if event["after"] != head:
                raise ValueError("Push head mismatch")
            base = commit(repo, event["before"])
            git(repo, "merge-base", "--is-ancestor", base, head)
        else:
            raise ValueError("Unsupported event")
        raw = git(repo, "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
                  "--name-only", "-z", base, head, "--")
        if raw and not raw.endswith(b"\0"):
            raise ValueError("Incomplete changed-file list")
        paths = tuple(raw[:-1].decode("utf-8").split("\0")) if raw else ()
        scope = classify(paths)
        return Scope(scope.full_checks, scope.reason, scope.paths, base, head)
    except (OSError, ValueError, TypeError, KeyError, subprocess.CalledProcessError):
        return Scope(True, "Change baseline or event could not be verified; full verification required.")


def main():
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
        scope = event_scope(Path.cwd(), os.environ.get("GITHUB_EVENT_NAME"), event,
                            os.environ.get("GITHUB_SHA"))
    except (OSError, ValueError, KeyError):
        scope = Scope(True, "Event metadata unavailable; full verification required.")
    print(json.dumps(asdict(scope), sort_keys=True))
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a", encoding="utf-8") as stream:
            stream.write(f"full_checks={str(scope.full_checks).lower()}\n")
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a", encoding="utf-8") as stream:
            stream.write("### Verification scope\n\n" + scope.reason + "\n\n")
            if scope.full_checks:
                stream.write("Full verification is required. Classification is not a test result.\n")
            else:
                stream.write("Package/native verification is **not applicable** to this change. "
                             "Those tests were not run and are not reported as passed. "
                             "This scope result does not certify the baseline runtime or replay "
                             "previous acceptance. "
                             "Golden/contract, vendor and supply-chain gates still run.\n")
            if scope.base:
                stream.write(f"\nCompared `{scope.base}` → `{scope.head}` "
                             f"({len(scope.paths)} changed paths).\n")


if __name__ == "__main__":
    main()
