#!/usr/bin/env python3
"""Independent single-user chat reference; Jinja2 is a maintainer-only oracle."""
import argparse
import hashlib
import json
from pathlib import Path
import jinja2
from jinja2.sandbox import ImmutableSandboxedEnvironment

DIRECTORY = Path(__file__).resolve().parent
SOURCES = {
    "qwen35-author.jinja": ("qwen35", "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"),
    "qwen35-gguf.jinja": ("qwen35", "7f0e529032c25183bcd66c7f238da2d377f43be754a94e2725a58c4e16d2ed67"),
    "gemma4.jinja": ("gemma4", "ae53464bf3be25802b3a5b37def7fd89667067d7577049b3b2d74c4d8de4c6d4"),
}

def render():
    if jinja2.__version__ != "3.1.6":
        raise RuntimeError("Reference renderer requires Jinja2 3.1.6")
    env = ImmutableSandboxedEnvironment(trim_blocks=True, lstrip_blocks=True)
    def refuse(message):
        raise ValueError(message)
    env.globals["raise_exception"] = refuse
    cases = []
    for filename, (architecture, digest) in SOURCES.items():
        raw = (DIRECTORY / filename).read_bytes()
        if hashlib.sha256(raw).hexdigest() != digest:
            raise RuntimeError(f"Template bytes changed: {filename}")
        template = env.from_string(raw.decode())
        for name, prompt in [
            ("ascii", "Compatibility probe"),
            ("unicode", "Café 😀 e\u0301\nLine two\tend."),
            ("whitespace", " \t\n  Keep internal  spaces.\r\n  "),
            ("python-strip-controls", "\u001c\u001d\u001e\u001f\u0085\u2007Keep\ufeff\u2007\u0085\u001f"),
            ("empty", ""),
            ("literal-markers", "Show <|turn> and <think> literally: {\"a\": 1}."),
        ]:
            for add_assistant in (False, True):
                for structured in (False, True):
                    arguments = {"messages": [{"role": "user", "content": prompt}],
                                 "add_generation_prompt": add_assistant, "tools": None,
                                 "bos_token": "<bos>"}
                    if structured:
                        arguments["enable_thinking"] = False
                    text = template.render(**arguments)
                    cases.append({"name": f"{filename}/{name}/{add_assistant}/{structured}",
                                  "template": filename, "architecture": architecture,
                                  "prompt": prompt, "add_assistant": add_assistant,
                                  "structured": structured, "rendered": text,
                                  "sha256": hashlib.sha256(text.encode()).hexdigest()})
    return {"renderer": "Jinja2 3.1.6 ImmutableSandboxedEnvironment",
            "template_sha256": {k: v[1] for k, v in SOURCES.items()}, "cases": cases}

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    options = parser.parse_args()
    data = (json.dumps(render(), ensure_ascii=True, indent=2) + "\n").encode()
    target = DIRECTORY / "single-user-turn.json"
    if options.write:
        target.write_bytes(data)
    elif target.read_bytes() != data:
        raise RuntimeError("Committed reference differs from pinned Jinja render")
    print("72 single-user cases match the three pinned source templates.")
