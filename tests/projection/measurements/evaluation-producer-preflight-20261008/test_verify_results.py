#!/usr/bin/env python3
"""Synthetic collector controls only: no model, product code, or old golden run."""
import copy
import csv
import importlib.util
import io
import json
from pathlib import Path
import random
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("f6e_verifier", Path(__file__).with_name("verify_results.py"))
v = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(v)

RNG = random.Random(17)  # Synthetic indices; never represented as real R RNG output.
SYNTHETIC_SIGNS = [-1] * 6 + [1] * 6
SYNTHETIC_INDICES = [[RNG.randrange(1, 9) for _ in range(8)] for _ in range(2000)]


def csv_bytes(columns, rows):
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=columns, lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    return output.getvalue().encode("utf-8")


class SyntheticBundle:
    """Fabricated receipt shape for verifier tests, not scientific evidence."""
    def __init__(self, root):
        self.root = root
        self.manifest, self.prompts = v.pinned_inputs()
        self.rows = {}
        self.data = dict(schema=v.SCHEMA_VERSION, protocol_sha256=v.PROTOCOL_SHA,
            manifest_sha256=v.MANIFEST_SHA, prompts_sha256=v.PROMPTS_SHA,
            identity=dict(model_sha256=v.MODEL_SHA, backend="cpu", context_length=512, layer=12,
                package_version="synthetic-control", engine_revision="synthetic-control", source_revision="a" * 40,
                r_version="4.5.1", dll_sha256="b" * 64,
                cpu_evidence=self.put("cpu.json", json.dumps(dict(backend="cpu", n_gpu_layers=0, model_sha256=v.MODEL_SHA)).encode()),
                installed_evidence=self.put("installed.txt", b"SYNTHETIC CONTROL; not an installed package")),
            rng=copy.deepcopy(v.SCHEMA["rng_exact_fields"]), producer_sources=["collector.R"],
            artifacts={key: self.put("artifacts/" + key + ".rds", ("SYNTHETIC " + key).encode()) for key in ("residual", "mlp", "random_mlp")},
            files={key: None for key in v.FILE_KEYS})
        source_rows = []
        for i, source in enumerate(["docs/f6e-evaluation-protocol.md", "tests/projection/evaluation/manifest.json",
                "tests/projection/evaluation/prompts.csv", "tests/projection/evaluation/verify_results.py", "collector.R"]):
            raw = (v.REPO / source).read_bytes() if source != "collector.R" else b"# Synthetic collector; not executable model code\n"
            entry = self.put(f"sources/{i}.txt", raw)
            source_rows.append(dict(source=source, snapshot_file=entry["file"], sha256=entry["sha256"]))
        for key in ("sources_before", "sources_after"):
            self.set_table(key, v.SOURCE_COLUMNS, source_rows)
        construction = []
        for prompt in [row for row in self.prompts if row["split"] == "construction"]:
            entry = self.put(f"capture/{prompt['item_id']}-{prompt['role']}.rds", ("SYNTHETIC " + prompt["prompt"]).encode())
            construction.append(dict(item_id=prompt["item_id"], role=prompt["role"], prompt_sha256=prompt["prompt_sha256"],
                source_pos="17" if prompt["role"] == "target" else "23", capture_file=entry["file"], capture_sha256=entry["sha256"]))
        self.set_table("construction", v.CONSTRUCTION_COLUMNS, construction)
        names = [row["item_id"] for row in construction if row["role"] == "target"]
        self.set_table("random_signs", ["item_id", "sign"], [dict(item_id=name, sign=str(sign)) for name, sign in zip(names, SYNTHETIC_SIGNS)])
        pairs = []
        indexed = {(row["item_id"], row["role"]): row for row in construction}
        for artifact in ("residual", "mlp", "random_mlp"):
            for i, name in enumerate(names):
                roles = ("control", "target") if artifact == "random_mlp" and SYNTHETIC_SIGNS[i] == -1 else ("target", "control")
                a, b = [indexed[(name, role)] for role in roles]
                pairs.append(dict(artifact=artifact, item_id=name, target_sha256=a["prompt_sha256"], control_sha256=b["prompt_sha256"], target_pos=a["source_pos"], control_pos=b["source_pos"]))
        self.set_table("artifact_pairs", v.PAIR_COLUMNS, pairs)
        self.set_table("bootstrap", v.SCHEMA["bootstrap_columns"], [dict(replicate=str(i + 1), **{f"draw{j + 1}": str(value) for j, value in enumerate(draw)}) for i, draw in enumerate(SYNTHETIC_INDICES)])
        selection = []
        for prompt in [row for row in self.prompts if row["split"] == "selection"]:
            for setting in self.manifest["selection_settings"]:
                ordinal = len(selection) + 1
                selection.append(self.run(ordinal, f"s{ordinal:03}", "selection", prompt, setting, None, ""))
        self.set_table("selection", v.RUN_COLUMNS, selection)
        self.save()

    def put(self, name, raw):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        return dict(file=name, sha256=v.sha(raw))
    def set_table(self, key, columns, rows):
        self.rows[key] = copy.deepcopy(rows)
        self.data["files"][key] = self.put(key + ".csv", csv_bytes(columns, rows))
    def save(self): (self.root / "receipt.json").write_text(json.dumps(self.data))
    def verify(self, stage):
        with patch.object(v, "real_r_rng", return_value=("4.5.1", SYNTHETIC_SIGNS, SYNTHETIC_INDICES)):
            return v.verify_bundle(self.root, stage)
    def events(self, run_id, text, failed=False, count=2, finish="stop", token_id=11):
        rows = []
        for i in range(count):
            rows.append(dict(event_id=str(len(rows) + 1), event="token", prompt_id="1", token_pos=str(i + 1), token_id=str(token_id + i), text="", elapsed=str((i + 1) / 1000), finish_reason="", validated=""))
        if text:
            rows.append(dict(event_id=str(len(rows) + 1), event="text", prompt_id="1", token_pos="", token_id="", text=text, elapsed=str((count + 1) / 1000), finish_reason="", validated=""))
        if not failed:
            rows.append(dict(event_id=str(len(rows) + 1), event="prompt_end", prompt_id="1", token_pos="", token_id="", text="", elapsed=str((count + 2) / 1000), finish_reason=finish, validated=""))
        return self.put(f"raw/{run_id}.events.csv", csv_bytes(v.EVENT_COLUMNS, rows))
    def run(self, ordinal, run_id, phase, prompt, setting, selected, lock_sha):
        operator, coef, artifact = v.setting_spec(setting, selected)
        answer = prompt["required_pattern"].split("|")[0]
        short = (setting.startswith("add_") or setting.startswith("project_") or setting == "selected_project")
        text = answer + ("." if short else ". A longer baseline response.")
        view = phase == "view"
        text_entry = self.put(f"raw/{run_id}.txt", text.encode()) if not view else dict(file="", sha256="")
        event_entry = self.events(run_id, "Jane" if view else text, failed=view, count=1 if view else 2)
        error_entry = self.put(f"raw/{run_id}.error.csv", csv_bytes(["class", "reason", "message"],
            [dict(**{"class": "relm_error_cancelled", "reason": "requested", "message": "Synthetic two-state cancellation"})])) if view else dict(file="", sha256="")
        return dict(ordinal=str(ordinal), run_id=run_id, phase=phase, item_id=prompt["item_id"], setting=setting,
            operator=operator, coefficient=str(coef), artifact=artifact, artifact_sha256=self.data["artifacts"][artifact]["sha256"] if artifact else "",
            prompt_sha256=prompt["prompt_sha256"], request_seed="1046", returned_seed="" if view else "1046", chat="FALSE", temperature="0", top_p="0.95", max_tokens="256",
            stop_is_null="TRUE", images_is_null="TRUE", schema_is_null="TRUE", **{"async": "TRUE"}, on_state="TRUE" if view else "FALSE", watchdog_seconds="120",
            status="cancelled" if view else "ok", started_unix=str(1000 + ordinal * 2), ended_unix=str(1001 + ordinal * 2), elapsed_seconds="1",
            text_file=text_entry["file"], text_sha256=text_entry["sha256"], events_file=event_entry["file"], events_sha256=event_entry["sha256"],
            error_file=error_entry["file"], error_sha256=error_entry["sha256"], selection_lock_sha256=lock_sha)
    def complete(self):
        report = self.verify("selection")
        descriptor = self.put("selection-report.json", json.dumps(report).encode())
        lock = dict(schema="F6e-selection-lock/1", selected_add=report["selected"]["add"], selected_project=report["selected"]["project"],
            selection_evidence_sha256=report["selection_evidence_sha256"], selection_report=descriptor, verifier_sha256=report["verifier_sha256"], locked_at_unix=1145.5)
        lock_descriptor = self.put("selection-lock.json", json.dumps(lock).encode())
        self.data["files"]["selection_lock"] = lock_descriptor
        final = []
        for prompt in [row for row in self.prompts if row["split"] == "evaluation"]:
            for setting in self.manifest["final_settings"]:
                i = len(final) + 1
                final.append(self.run(i + 72, f"e{i:03}", "evaluation", prompt, setting, report["selected"], lock_descriptor["sha256"]))
        self.set_table("evaluation", v.RUN_COLUMNS, final)
        prompt = self.prompts[0]
        views = [self.run(121 + i, f"v{i + 1:03}", "view", prompt, setting, report["selected"], lock_descriptor["sha256"]) for i, setting in enumerate(("baseline", "selected_project"))]
        self.set_table("views", v.RUN_COLUMNS, views)
        states = []
        for view in views:
            for state in (1, 2):
                entry = self.put(f"states/{view['run_id']}-{state}.rds", f"SYNTHETIC STATE {view['run_id']} {state}".encode())
                states.append(dict(run_id=view["run_id"], state_id=str(state), prompt_token_count="17", source_pos=str(16 + state), source_token_id="42" if state == 1 else "11",
                                   generated_prefix_ids="" if state == 1 else "11", state_file=entry["file"], state_sha256=entry["sha256"]))
        self.set_table("view_states", v.STATE_COLUMNS, states)
        self.save()


class VerifierControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="f6e-verifier-synthetic-")
        self.bundle = SyntheticBundle(Path(self.temporary.name))
    def tearDown(self): self.temporary.cleanup()
    def rejected(self, mutation, stage="selection"):
        mutation()
        self.bundle.save()
        with self.assertRaises(v.VerificationError): self.bundle.verify(stage)
    def table_change(self, key, columns, action):
        rows = copy.deepcopy(self.bundle.rows[key]); action(rows); self.bundle.set_table(key, columns, rows)

    def test_positive_selection_and_complete_recompute(self):
        selection = self.bundle.verify("selection")
        self.assertEqual(selection["selected"], {"add": -1, "project": .5})
        self.bundle.complete()
        full = self.bundle.verify("complete")
        self.assertEqual(full["observations"], 122)
        self.assertEqual(len(full["intervals"]), 36)
        self.assertEqual(full["views"]["aligned_state_ids"], [1, 2])
    def test_missing_selection_run(self):
        self.rejected(lambda: self.table_change("selection", v.RUN_COLUMNS, lambda rows: rows.pop()))
    def test_duplicate_selection_run(self):
        self.rejected(lambda: self.table_change("selection", v.RUN_COLUMNS, lambda rows: rows.__setitem__(1, rows[0])))
    def test_prompt_leakage(self):
        self.rejected(lambda: self.table_change("selection", v.RUN_COLUMNS, lambda rows: rows[0].update(prompt_sha256=self.bundle.prompts[-1]["prompt_sha256"])))
    def test_token_cap_retuning(self):
        self.rejected(lambda: self.table_change("selection", v.RUN_COLUMNS, lambda rows: rows[3].update(max_tokens="64")))
    def test_seed_attribute_not_assumed_from_request(self):
        self.rejected(lambda: self.table_change("selection", v.RUN_COLUMNS, lambda rows: rows[3].update(returned_seed="")))
    def test_raw_output_hash_corruption(self):
        row = self.bundle.rows["selection"][3]
        self.rejected(lambda: (self.bundle.root / row["text_file"]).write_text("tampered"))
    def test_recomputed_hash_does_not_hide_text_event_disagreement(self):
        def mutate():
            rows = self.bundle.rows["selection"]
            rows[3]["text_sha256"] = self.bundle.put(rows[3]["text_file"], b"different")['sha256']
            self.bundle.set_table("selection", v.RUN_COLUMNS, rows)
        self.rejected(mutate)
    def test_source_drift(self):
        self.rejected(lambda: self.table_change("sources_after", v.SOURCE_COLUMNS, lambda rows: rows.pop()))
    def test_swapped_random_roles_must_be_truthful(self):
        self.rejected(lambda: self.table_change("artifact_pairs", v.PAIR_COLUMNS, lambda rows: rows[-12].update(target_pos="17")))
    def test_bootstrap_indices_not_merely_shape_checked(self):
        self.rejected(lambda: self.table_change("bootstrap", v.SCHEMA["bootstrap_columns"], lambda rows: rows[0].update(draw1=str(1 + int(rows[0]["draw1"]) % 8))))
    def test_signs_not_merely_balanced_checked(self):
        def mutate(rows): rows[0]["sign"], rows[6]["sign"] = rows[6]["sign"], rows[0]["sign"]
        self.rejected(lambda: self.table_change("random_signs", ["item_id", "sign"], mutate))
    def test_coefficient_retuning_final(self):
        self.bundle.complete()
        self.rejected(lambda: self.table_change("evaluation", v.RUN_COLUMNS, lambda rows: rows[3].update(coefficient="2")), "complete")
    def test_final_before_selection_lock(self):
        self.bundle.complete()
        self.rejected(lambda: self.table_change("evaluation", v.RUN_COLUMNS, lambda rows: rows[0].update(started_unix="1145")), "complete")
    def test_postlock_selection_change(self):
        self.bundle.complete()
        self.rejected(lambda: self.table_change("selection", v.RUN_COLUMNS, lambda rows: rows[3].update(elapsed_seconds="1.1")), "complete")
    def test_zero_semantics_not_hidden_by_success(self):
        def mutate():
            rows = self.bundle.rows["selection"]
            raw = self.bundle.root / rows[1]["events_file"]
            events = v.csv_rows(raw.read_bytes(), v.EVENT_COLUMNS)
            events[0]["token_id"] = "99"
            rows[1]["events_sha256"] = self.bundle.put(rows[1]["events_file"], csv_bytes(v.EVENT_COLUMNS, events))["sha256"]
            self.bundle.set_table("selection", v.RUN_COLUMNS, rows)
        self.rejected(mutate)
    def test_duplicate_json_fields_rejected(self):
        with self.assertRaises(v.VerificationError): v.read_json(b'{"a":1,"a":2}')
    def test_malformed_csv_and_nonfinite_rejected(self):
        with self.assertRaises(v.VerificationError): v.csv_rows(b'a,b\n"unterminated', ["a", "b"])
        with self.assertRaises(v.VerificationError): v.number("NaN")
    def test_metric_unicode_literal_and_repeat_controls(self):
        result = v.metric_values("Oslo_ ОСЛО éé 🚀 foo foo foo", "Oslo", 7, "length")
        self.assertEqual(result, dict(required=1, characters=27, tokens=7, empty=0, truncated=1, repeated=2))
        self.assertEqual(v.metric_values("Oslofjord", "Oslo", 1, "stop")["required"], 0)
        self.assertEqual(v.metric_values("NA", "NA", 1, "stop")["characters"], 2)
        self.assertEqual(v.metric_values(" \t\n", "x", 0, "stop")["empty"], 1)
    def test_type7_and_paired_resampling_controls(self):
        self.assertAlmostEqual(v.quantile7([0, 10, 20, 30], .25), 7.5)
        self.bundle.complete()
        full = self.bundle.verify("complete")
        interval = next(row for row in full["intervals"] if row["setting"] == "selected_project" and row["reference"] == "baseline" and row["metric"] == "characters")
        self.assertEqual(interval["estimate"], -28)
        self.assertEqual(interval["conf_low"], interval["conf_high"])
    def test_every_selection_quality_guard_and_zero_fallback(self):
        rows = self.bundle.verify("selection")["selection"]
        for metric, changed in (("required", 0), ("empty", 1), ("truncated", 1), ("repeated", 1)):
            with self.subTest(metric=metric):
                changed_rows = copy.deepcopy(rows)
                candidate = next(row for row in changed_rows if row["setting"] == "add_-1")
                candidate["metrics"][metric] = changed
                selected, _ = v.selected_coefficients(changed_rows, self.bundle.manifest)
                self.assertEqual(selected["add"], 1)
        failed = copy.deepcopy(rows)
        candidate = next(row for row in failed if row["setting"] == "add_-1")
        candidate.update(status="error", metrics=None)
        self.assertEqual(v.selected_coefficients(failed, self.bundle.manifest)[0]["add"], 1)
        baseline = {row["item_id"]: row for row in rows if row["setting"] == "baseline"}
        for row in rows:
            if row["setting"].startswith("add_"):
                row["metrics"]["characters"] = baseline[row["item_id"]]["metrics"]["characters"]
        self.assertEqual(v.selected_coefficients(rows, self.bundle.manifest)[0]["add"], 0)
    def test_failed_selection_baseline_invalidates_selection(self):
        rows = self.bundle.verify("selection")["selection"]
        rows[0].update(status="error", metrics=None)
        with self.assertRaises(v.VerificationError): v.selected_coefficients(rows, self.bundle.manifest)
    def test_zero_elapsed_is_not_a_false_determinism_failure(self):
        rows = self.bundle.rows["selection"]
        raw = self.bundle.root / rows[1]["events_file"]
        events = v.csv_rows(raw.read_bytes(), v.EVENT_COLUMNS)
        for event in events: event["elapsed"] = str(float(event["elapsed"]) + .1)
        rows[1]["events_sha256"] = self.bundle.put(rows[1]["events_file"], csv_bytes(v.EVENT_COLUMNS, events))["sha256"]
        self.bundle.set_table("selection", v.RUN_COLUMNS, rows); self.bundle.save()
        self.assertEqual(self.bundle.verify("selection")["observations"], 72)
    def test_finish_and_token_event_mutations_are_rejected(self):
        entry = self.bundle.events("event-control", "word")
        original = v.csv_rows((self.bundle.root / entry["file"]).read_bytes(), v.EVENT_COLUMNS)
        variants = []
        variants.append(original[:-1])
        changed = copy.deepcopy(original); changed.append(changed[-1]); variants.append(changed)
        changed = copy.deepcopy(original); changed[0]["token_pos"] = "2"; variants.append(changed)
        changed = copy.deepcopy(original); changed[-1]["finish_reason"] = "length"; variants.append(changed)
        changed = copy.deepcopy(original); changed[1]["elapsed"] = "0"; variants.append(changed)
        for events in variants:
            with self.subTest(events=events):
                with self.assertRaises(v.VerificationError): v.inspect_events(csv_bytes(v.EVENT_COLUMNS, events), "ok", "word")
    def test_actual_length_finish_is_retained_in_primary_metrics(self):
        entry = self.bundle.events("length-control", "Oslo", count=256, finish="length")
        tokens, finish, _, _ = v.inspect_events((self.bundle.root / entry["file"]).read_bytes(), "ok", "Oslo")
        self.assertEqual(v.metric_values("Oslo", "Oslo", len(tokens), finish)["truncated"], 1)
    def test_unaligned_second_view_is_reported_not_compared(self):
        self.bundle.complete()
        views = self.bundle.rows["views"]
        entry = self.bundle.events("v002", "Jane", failed=True, count=1, token_id=19)
        views[1].update(events_file=entry["file"], events_sha256=entry["sha256"])
        self.bundle.set_table("views", v.RUN_COLUMNS, views)
        states = self.bundle.rows["view_states"]
        states[-1].update(source_token_id="19", generated_prefix_ids="19")
        self.bundle.set_table("view_states", v.STATE_COLUMNS, states); self.bundle.save()
        self.assertEqual(self.bundle.verify("complete")["views"]["unaligned_state_ids"], [2])
    def test_missing_final_and_retuned_lock_rejected(self):
        self.bundle.complete()
        original = copy.deepcopy(self.bundle.rows["evaluation"])
        self.rejected(lambda: self.table_change("evaluation", v.RUN_COLUMNS, lambda rows: rows.pop()), "complete")
        self.bundle.set_table("evaluation", v.RUN_COLUMNS, original)
        lock = v.read_json((self.bundle.root / "selection-lock.json").read_bytes())
        lock["selected_project"] = 2
        self.rejected(lambda: self.bundle.data["files"].update(selection_lock=self.bundle.put("selection-lock.json", json.dumps(lock).encode())), "complete")

    def test_failed_final_learned_call_withholds_fixed_sample(self):
        self.bundle.complete()
        rows = self.bundle.rows["evaluation"]
        row = rows[4]
        row.update(status="error", returned_seed="", text_file="", text_sha256="")
        events = self.bundle.events(row["run_id"], "partial", failed=True)
        error = self.bundle.put("raw/e005.error.csv", csv_bytes(["class", "reason", "message"], [dict(**{"class": "relm_error_generation", "reason": "test", "message": "Synthetic failure"})]))
        row.update(events_file=events["file"], events_sha256=events["sha256"], error_file=error["file"], error_sha256=error["sha256"])
        self.bundle.set_table("evaluation", v.RUN_COLUMNS, rows); self.bundle.save()
        report = self.bundle.verify("complete")
        affected = [row for row in report["intervals"] if row["setting"] == "selected_project"]
        self.assertEqual(len(affected), 12)
        self.assertTrue(all(row["status"] == "withheld" and row["estimate"] is None and row["n_tasks"] == 8 for row in affected))


if __name__ == "__main__": unittest.main()
