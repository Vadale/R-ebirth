#!/usr/bin/env python3
"""Check a fixture-only batch artifact convention; this is not a batch runner."""
import copy
import hashlib
import json

from verify import ROOT, check_record, loads


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def canonical(value):
    # Fixture convention: sorted keys, compact UTF-8, no floats/nonfinite values.
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, allow_nan=False).encode("utf-8")


def resume_actions(fixture, requested_config):
    """Pure identity/state assertions; no inference, locking or filesystem writes."""
    config = fixture["manifest"]["config"]
    identity = digest(canonical(config))
    assert fixture["fixture_only"] is True
    assert fixture["manifest"]["run_identity"] == identity
    assert canonical(requested_config) == canonical(config), "Changed run: use a new directory"
    documents = {d["id"]: d for d in config["documents"]}
    assert len(documents) == len(config["documents"]), "Duplicate input ID"
    results = {}
    for result in fixture["results"]:
        key = result["id"]
        assert key in documents and key not in results, "Unknown/duplicate result ID"
        assert result["run_identity"] == identity, "Stale result identity"
        assert result["seed"] == documents[key]["seed"], "Changed seed"
        assert result["state"] in {"committed", "interrupted"}
        if result["state"] == "committed":
            assert result["status"] == "success"  # This example contains one success.
            assert digest(canonical(result["output"])) == result["output_sha256"]
        else:
            assert "output" not in result, "Interrupted output cannot be committed"
        results[key] = result
    return {key: "skip" if key in results and results[key]["state"] == "committed"
            else "retry" for key in documents}


def main():
    fixture = loads((ROOT / "batch-contract.json").read_text(encoding="utf-8"))
    config = fixture["manifest"]["config"]
    cases = {c["id"]: c for c in loads((ROOT / "cases.json").read_text(encoding="utf-8"))}
    assert config["model_sha256"] == digest(
        (ROOT.parent.parent / "rebirth/tests/testthat/fixtures/synthetic-llama-2l.gguf").read_bytes())
    assert config["schema_sha256"] == digest((ROOT / "output.schema.json").read_bytes())
    assert config["prompt_sha256"] == digest(fixture["prompt_template"].encode("utf-8"))
    for document in config["documents"]:
        case = cases[document["id"]]
        assert document["source_sha256"] == digest(canonical(
            {k: case[k] for k in ("target", "text")}))
    for result in fixture["results"]:
        if result["state"] == "committed":
            check_record(result["output"], cases[result["id"]]["text"])
    assert resume_actions(fixture, config) == fixture["expected_actions"]

    def rejected(changed, requested):
        try:
            resume_actions(changed, requested)
        except AssertionError:
            return
        raise AssertionError("Corrupt or stale batch contract accepted")

    for key in ("model_sha256", "prompt_sha256", "schema_sha256"):
        changed = copy.deepcopy(config); changed[key] = "0" * 64
        rejected(fixture, changed)
    changed = copy.deepcopy(config); changed["documents"][0]["source_sha256"] = "0" * 64
    rejected(fixture, changed)
    for key, value in (("run_identity", "0" * 64), ("seed", -1), ("output_sha256", "0" * 64)):
        changed = copy.deepcopy(fixture); changed["results"][0][key] = value
        rejected(changed, config)
    changed = copy.deepcopy(fixture); changed["results"].append(changed["results"][0])
    rejected(changed, config)
    changed = copy.deepcopy(fixture); changed["results"][1]["output"] = {}
    rejected(changed, config)
    print("PASS: fixture-only batch identities; committed skip, interrupted/missing retry; stale/corrupt rejection.")
    print("NOT TESTED: inference, atomic writes, process restart, locks or actual D2 execution.")


if __name__ == "__main__":
    main()
