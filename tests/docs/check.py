"""Bounded documentation inventory/link checks, stdlib only; no network/models.

Run from repository root: python tests/docs/check.py [SITE_DIRECTORY]
"""
import csv
import hashlib
from html.parser import HTMLParser
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit

root = Path.cwd()
rows = list(csv.DictReader((root / "docs/api-surface.csv").open()))
exports = {row["name"] for row in rows if row["kind"] == "export"}
examples = root / "rebirth/inst/examples/agents"
assert {p.stem for p in examples.glob("*.R")} == exports
assert len(exports) == 16 and len(rows) == 33
for row in rows:
    assert (root / "rebirth/man" / row["topic"]).is_file(), row
    assert row["signature"].startswith(row["name"] + "("), row
for path in examples.glob("*.R"):
    text = path.read_text()
    assert "run_example <- function(" in text, path
    assert "relm::" + path.stem + "(" in text, path
    assert not re.search(r"relm:::|install.packages|source\(", text), path

paths = [root / "llms.txt", root / "README.md"] + [root / "docs" / name for name in (
    "agents.md", "api-policy.md", "wp16-plan.md", "README.md", "getting-started.md",
    "models.md")]
paths += [root / "examples/funding-extraction/quickstart" / name
          for name in ("README.md", "recorded/README.md")]
# Bind the public recording to the adjacent recipe, without executing a model.
recipe = root / "examples/funding-extraction/quickstart"
recorded_inputs = list(csv.DictReader((recipe / "recorded/inputs.csv").open()))
assert len(recorded_inputs) == 6
assert {row["file"] for row in recorded_inputs} == {
    "notices.csv", "expected.csv", "prompt.txt", "schema.json", "settings.json", "run.R"}
for row in recorded_inputs:
    path = recipe / row["file"]
    assert path.parent == recipe and path.is_file(), row
    assert hashlib.sha256(path.read_bytes()).hexdigest() == row["sha256"], row
links = 0
for path in paths:
    text = path.read_text()
    for target in re.findall(r"\]\(([^)]+)\)", text):
        url = urlsplit(target)
        if url.scheme or not url.path:
            continue
        actual = (path.parent / unquote(url.path)).resolve()
        assert actual.is_relative_to(root) and actual.exists(), (path, target)
        links += 1
    assert not re.search(r"/home/|/Users/|THESIS-PLAN|plugin://|codex://", text), path
print(f"Source documentation: {len(exports)} exports, {len(rows)} public entries, {links} local links")

if len(sys.argv) == 2:
    site = Path(sys.argv[1]).resolve()
    for name in ("index.html", "reference/index.html", "articles/index.html",
                 "llms.txt", "llms-full.txt", "api-surface.csv"):
        assert (site / name).is_file(), name
    for row in rows:
        assert (site / "reference" / row["topic"].replace(".Rd", ".html")).is_file(), row
    for name in exports:
        assert (site / "agents" / (name + ".R")).read_bytes() == (examples / (name + ".R")).read_bytes()
    for name in ("agents", "api-policy", "getting-started", "models", "research-guide",
                 "supported-workflow", "cran-submission"):
        html = (site / "articles" / (name + ".html")).read_text()
        assert f"https://github.com/Vadale/R-ebirth/blob/main/docs/{name}.md" in html
        assert f"vignettes/articles/{name}.Rmd" not in html

    class Links(HTMLParser):
        def __init__(self):
            super().__init__()
            self.links = []
            self.ids = set()

        def handle_starttag(self, tag, attrs):
            attrs = dict(attrs)
            if "id" in attrs:
                self.ids.add(attrs["id"])
            for key in ("href", "src"):
                if key in attrs:
                    self.links.append(attrs[key])

    documents = {}
    for path in site.rglob("*.html"):
        parser = Links()
        parser.feed(path.read_text())
        documents[path.resolve()] = parser
    checked = 0
    for path, document in documents.items():
        for link in document.links:
            url = urlsplit(link)
            if url.scheme or url.netloc or link.startswith("/"):
                continue
            target = (path.parent / unquote(url.path)).resolve() if url.path else path
            if target.is_dir():
                target /= "index.html"
            assert target.is_relative_to(site) and target.exists(), (path, link)
            if url.fragment and target in documents:
                assert unquote(url.fragment) in documents[target].ids, (path, link)
            checked += 1
    print(f"Rendered documentation: {len(documents)} HTML pages, {checked} links/anchors")
