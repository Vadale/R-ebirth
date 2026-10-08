#!/usr/bin/env python3
"""Independent, model-free Spark chat oracle; Jinja2 is a dev-only dependency."""

import argparse
import hashlib
import json
from pathlib import Path

import jinja2
from jinja2.sandbox import ImmutableSandboxedEnvironment

DIRECTORY = Path(__file__).resolve().parent
REVISION = "0bcb35678590218655dff3765b9e61c83b35e9c4"
TEMPLATE_SHA256 = {
    "chat_template.jinja": "705345721970da40e6aa56db548a46ecd1d8d94a5418808fa180ac19ee77a9ba",
    "tokenizer-chat-template.jinja": "25576c2aaec931fce04fedbd6ba06de209e553673858073120697884316158fe",
}


def render_fixtures():
    if jinja2.__version__ != "3.1.6":
        raise RuntimeError("The reference renderer is pinned to Jinja2 3.1.6")
    environment = ImmutableSandboxedEnvironment(trim_blocks=True, lstrip_blocks=True)

    def raise_exception(message):
        raise ValueError(message)

    environment.globals["raise_exception"] = raise_exception
    templates = []
    for filename, digest in TEMPLATE_SHA256.items():
        data = (DIRECTORY / filename).read_bytes()
        if hashlib.sha256(data).hexdigest() != digest:
            raise RuntimeError(f"Source template digest mismatch: {filename}")
        templates.append(environment.from_string(data.decode("utf-8")))

    cases = []
    for name, prompt, add_assistant in [
        ("ascii", "Hello.", True),
        ("unicode", "Unicode: café 😀 e\u0301\nLine two\tend.", True),
        ("empty", "", True),
        ("whitespace", "  Preserve this whitespace.\n\n", True),
        ("no-assistant", "Hello.", False),
    ]:
        for structured in [False, True]:
            arguments = {
                "messages": [{"role": "user", "content": prompt}],
                "add_generation_prompt": add_assistant,
                "tools": None,
            }
            # Ordinary generation intentionally exercises the author's default.
            if structured:
                arguments["enable_thinking"] = False
            rendered = [template.render(**arguments) for template in templates]
            if rendered[0] != rendered[1]:
                raise RuntimeError("The two official template spellings disagree")
            cases.append({
                "name": f"{name}-{'structured' if structured else 'ordinary'}",
                "prompt": prompt,
                "structured": structured,
                "add_assistant": add_assistant,
                "rendered": rendered[0],
                "rendered_sha256": hashlib.sha256(rendered[0].encode("utf-8")).hexdigest(),
            })
    return {
        "source_repository": "XHToken/Spark-X2.5-4B",
        "source_revision": REVISION,
        "renderer": "Jinja2 3.1.6 ImmutableSandboxedEnvironment",
        "template_sha256": TEMPLATE_SHA256,
        "cases": cases,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="Write the independently rendered fixtures")
    arguments = parser.parse_args()
    expected = (json.dumps(render_fixtures(), indent=2, ensure_ascii=True) + "\n").encode()
    destination = DIRECTORY / "single-user-turn.json"
    if arguments.write:
        destination.write_bytes(expected)
        print("Wrote 10 Spark single-user-turn fixtures from both pinned official templates.")
    elif destination.read_bytes() != expected:
        raise RuntimeError("Committed Spark fixtures differ from the official-template render")
    else:
        print("All 10 Spark fixtures match both pinned official templates byte-for-byte.")


if __name__ == "__main__":
    main()
