#!/usr/bin/env python3
"""Independent F6e-v1 raw-result verifier; no product imports or model execution.

--schema prints the frozen collector interface. --stage selection verifies 72
raw calls and emits the lock inputs before final inference. --stage complete
verifies 72+48+2 calls and recomputes fixed-sample paired intervals. The caller
executes only a literal, model-free base-R RNG snippet to check saved signs and
bootstrap indices. This does not authenticate actual model execution or weights.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import math
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
PROTOCOL_SHA = "59f925c7e36b4305bcd8e603419b2f50f3cfb7679acee6260e2e53a27756df62"
MANIFEST_SHA = "e5f07e6a99c7d604084ff7f8f3b1312633af0b17d428af457aa895624a1c5833"
PROMPTS_SHA = "9d29799bd4a26b64af4b6ea7a18f390fc318f754c53f39391389d5b5355d07b2"
MODEL_SHA = "ca59ca7f13d0e15a8cfa77bd17e65d24f6844b554a7b6c12e07a5f89ff76844e"
SCHEMA_VERSION = "F6e-results/1"
METRICS = ("required", "characters", "tokens", "empty", "truncated", "repeated")
RUN_COLUMNS = ["ordinal", "run_id", "phase", "item_id", "setting", "operator", "coefficient",
    "artifact", "artifact_sha256", "prompt_sha256", "request_seed", "returned_seed", "chat",
    "temperature", "top_p", "max_tokens", "stop_is_null", "images_is_null", "schema_is_null",
    "async", "on_state", "watchdog_seconds", "status", "started_unix", "ended_unix", "elapsed_seconds",
    "text_file", "text_sha256", "events_file", "events_sha256", "error_file", "error_sha256",
    "selection_lock_sha256"]
EVENT_COLUMNS = ["event_id", "event", "prompt_id", "token_pos", "token_id", "text", "elapsed", "finish_reason", "validated"]
SOURCE_COLUMNS = ["source", "snapshot_file", "sha256"]
CONSTRUCTION_COLUMNS = ["item_id", "role", "prompt_sha256", "source_pos", "capture_file", "capture_sha256"]
PAIR_COLUMNS = ["artifact", "item_id", "target_sha256", "control_sha256", "target_pos", "control_pos"]
STATE_COLUMNS = ["run_id", "state_id", "prompt_token_count", "source_pos", "source_token_id", "generated_prefix_ids", "state_file", "state_sha256"]
SIGN_ALGORITHM = "set.seed(1046); sample(rep(c(-1L, 1L), each = 6L))"
BOOTSTRAP_ALGORITHM = "set.seed(2046); t(replicate(2000L, sample.int(8L, 8L, replace = TRUE)))"
RNG_KINDS = ["Mersenne-Twister", "Inversion", "Rejection"]
FILE_KEYS = ["sources_before", "sources_after", "construction", "artifact_pairs", "random_signs", "bootstrap", "selection", "evaluation", "views", "view_states", "selection_lock"]
SCHEMA = {
    "schema": SCHEMA_VERSION,
    "bundle": "Directory with receipt.json; every file descriptor is {file: safe relative path, sha256: lowercase hex}.",
    "receipt_exact_fields": ["schema", "protocol_sha256", "manifest_sha256", "prompts_sha256", "identity", "rng", "producer_sources", "artifacts", "files"],
    "identity_exact_fields": ["model_sha256", "backend", "context_length", "layer", "package_version", "engine_revision", "source_revision", "r_version", "dll_sha256", "cpu_evidence", "installed_evidence"],
    "identity_notes": "backend=cpu, context_length=512, layer=12; cpu_evidence/installed_evidence are hashed file descriptors. The CPU evidence is JSON with at least backend='cpu', n_gpu_layers=0, model_sha256. r_version is as.character(getRversion()), e.g.4.5.1. Other identity strings are nonempty; source_revision is a Git SHA and dll_sha256 is SHA256.",
    "rng_exact_fields": {"kind": RNG_KINDS, "sign_seed": 1046, "bootstrap_seed": 2046, "sign_algorithm": SIGN_ALGORITHM, "bootstrap_algorithm": BOOTSTRAP_ALGORITHM},
    "producer_sources": "Nonempty list of original source names, including the executed R recipe; each must occur in both source tables.",
    "artifacts": "Exactly residual, mlp, random_mlp file descriptors for saved/reloaded trusted RDS artifacts. Integrity binding here; arithmetic and RDS validation remain the separate construction gate.",
    "files": {key: ("null until complete stage" if key in ("evaluation", "views", "view_states", "selection_lock") else "required descriptor") for key in FILE_KEYS},
    "runs_columns": RUN_COLUMNS,
    "runs_types": "CSV UTF8/LF, exact column order, no row names. Integer fields are canonical decimal; doubles finite decimal; logical fields exactly TRUE/FALSE. Missing numeric/character fields use empty fields, never literal NA. Raw UTF8 text file is unmodified returned character bytes, no added newline; returned_seed is attr(text,'seed') separately. All other text including literal NA is data.",
    "runs_values": {"ordinal": "1..72 selection;73..120 evaluation;121..122 view", "run_id": "s001..s072,e001..e048,v001..v002", "phase": "selection/evaluation/view", "order": "task-major frozen prompt order, then manifest setting order; views baseline then selected_project on construction f6e-c01 target", "operator": "none/add/project", "artifact": "empty for baseline, residual for add, mlp for learned project, random_mlp for random", "status": "ok/error/cancelled/timed_out", "settings": "chat FALSE, temperature 0, top_p .95, max_tokens 256, request_seed1046, stop/images/schema_is_null TRUE, async TRUE,on_state TRUE only views,watchdog120", "missing": "returned_seed/text descriptor empty on failure, error descriptor empty on success, selection_lock_sha256 empty for selection and required later", "time": "started_unix,ended_unix are common-clock POSIX seconds; elapsed_seconds is separately measured nonnegative elapsed time; calls must be sequential", "errors": "error file CSV exact columns class,reason,message with one row; class may be semicolon-separated condition classes; preserve original message"},
    "event_columns": EVENT_COLUMNS,
    "event_notes": "Exact WP10 schema. NA numeric/logical is empty; otherwise token IDs/positions are 1-based. Ordinary validated is always empty. On success exactly one terminal prompt_end; text events reconstruct returned bytes; on failure no prompt_end. Equality removes only elapsed, not token/text/end semantics.",
    "construction_columns": CONSTRUCTION_COLUMNS,
    "construction_notes": "24 rows in frozen construction prompt order; capture_file is the actual one-trace/two-component retained receipt per prompt, not fabricated model provenance. source_pos comes from trace.",
    "artifact_pairs_columns": PAIR_COLUMNS,
    "artifact_pairs_notes": "36 rows: artifacts residual,mlp,random_mlp; each in c01..c12 order. Learned roles unchanged; random roles and positions swapped iff saved sign is -1.",
    "signs_columns": ["item_id", "sign"],
    "bootstrap_columns": ["replicate"] + [f"draw{i}" for i in range(1, 9)],
    "bootstrap_notes": "2000 rows in replicate order, each 8 indices in1..8; generated once with the exact recorded base-R algorithm, not reseeded per replicate.",
    "sources_columns": SOURCE_COLUMNS,
    "sources_notes": "Before/after source sets and hashes must match; snapshots are bundle files. Include this verifier, frozen protocol/manifest/prompts and all producer_sources. Installed evidence remains separately bound; snapshots do not authenticate execution.",
    "selection_lock_exact_fields": ["schema", "selected_add", "selected_project", "selection_evidence_sha256", "selection_report", "verifier_sha256", "locked_at_unix"],
    "selection_lock_notes": "schema=F6e-selection-lock/1. Run verifier --stage selection to a fresh JSON report after72calls; store selected fields/evidence digest and report descriptor here. Lock time after selection and before final. Every later run binds SHA256 of this exact lock file. No final data enters selection.",
    "view_state_columns": STATE_COLUMNS,
    "view_notes": "Four rows, v001 thenv002,state_id1,2. Cancel in second on_state; expect one sampled token and requested relm_error_cancelled. generated_prefix_ids empty forstate1 and first1-basedtoken_id forstate2. source_pos=P+state_id-1. Retain actual full state RDS via descriptor; only compare states with equal prompt hash and generated prefix. These calls are excluded from efficacy metrics.",
    "metrics": list(METRICS),
    "metric_rules": "required uses case-insensitive literal alternatives split by | and Unicode non-alphanumeric boundaries;characters counts Unicode code points;tokens counts token events;empty uses whitespace-only;truncated means finish_reason length;repeated counts adjacent equal lowercase whitespace tokens, preserving punctuation. Errors have no six-metric outcome; affected fixed-eight-task contrasts are withheld without case deletion.",
    "intervals": "Five nonbaseline settings vs baseline plus selected_project vs selected_add; six metrics; same2000pairedtaskresamples; percentile95% using R default quantile type7; no population/multiplicity claim.",
    "pins": {"protocol_sha256": PROTOCOL_SHA, "manifest_sha256": MANIFEST_SHA, "prompts_sha256": PROMPTS_SHA, "model_sha256": MODEL_SHA},
}


class VerificationError(ValueError):
    pass


def require(ok, message):
    if not ok: raise VerificationError(message)


def sha(data): return hashlib.sha256(data).hexdigest()
def canonical(value): return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
def integer(text):
    require(isinstance(text, str) and re.fullmatch(r"0|-?[1-9][0-9]*", text) is not None, "noncanonical integer")
    return int(text)
def number(text):
    try: value = float(text)
    except (ValueError, TypeError): raise VerificationError("invalid numeric value") from None
    require(math.isfinite(value), "nonfinite numeric value")
    return value

def object_pairs(pairs):
    output = {}
    for name, value in pairs:
        require(name not in output, "duplicate JSON field: " + name)
        output[name] = value
    return output

def read_json(raw):
    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=object_pairs,
                          parse_constant=lambda value: (_ for _ in ()).throw(VerificationError("nonfinite JSON " + value)))
    except (UnicodeError, json.JSONDecodeError) as error: raise VerificationError("invalid JSON") from error

def exact_fields(value, fields, label):
    require(type(value) is dict and set(value) == set(fields), "wrong fields: " + label)

def csv_rows(raw, columns):
    try:
        text = raw.decode("utf-8", errors="strict")
        require("\x00" not in text and not text.startswith("\ufeff"), "NUL/BOM in CSV")
        reader = csv.reader(io.StringIO(text, newline=""), strict=True)
        require(next(reader, None) == columns, "CSV header differs: " + ",".join(columns))
        rows = []
        for row in reader:
            require(len(row) == len(columns), "CSV row width differs")
            rows.append(dict(zip(columns, row)))
        return rows
    except (UnicodeError, csv.Error) as error: raise VerificationError("malformed CSV") from error


class Bundle:
    def __init__(self, directory):
        self.root = Path(directory).resolve()
        self.used = {}
        self.data = read_json((self.root / "receipt.json").read_bytes())
    def read(self, descriptor):
        exact_fields(descriptor, ["file", "sha256"], "file descriptor")
        name, checksum = descriptor["file"], descriptor["sha256"]
        require(type(name) is str and name and name == Path(name).as_posix() and not Path(name).is_absolute() and ".." not in Path(name).parts, "unsafe evidence path")
        path = (self.root / name).resolve()
        require(path.is_relative_to(self.root) and path.is_file(), "missing/outside evidence file: " + name)
        require(type(checksum) is str and re.fullmatch("[0-9a-f]{64}", checksum), "invalid SHA256")
        raw = path.read_bytes()
        require(sha(raw) == checksum, "evidence hash mismatch: " + name)
        self.used[name] = checksum
        return raw
    def rows(self, descriptor, columns): return csv_rows(self.read(descriptor), columns)


def pinned_inputs():
    protocol = REPO / "docs/f6e-evaluation-protocol.md"
    require(sha(protocol.read_bytes()) == PROTOCOL_SHA, "frozen protocol changed")
    manifest = (HERE / "manifest.json").read_bytes()
    prompts = (HERE / "prompts.csv").read_bytes()
    require(sha(manifest) == MANIFEST_SHA and sha(prompts) == PROMPTS_SHA, "frozen input changed")
    rows = csv_rows(prompts, ["item_id", "split", "role", "question", "prompt", "required_pattern", "prompt_sha256"])
    require(len(rows) == 38 and len({row["prompt_sha256"] for row in rows}) == 38, "prompt split overlap")
    for row in rows: require(sha(row["prompt"].encode("utf-8")) == row["prompt_sha256"], "prompt byte digest differs")
    return read_json(manifest), rows


def real_r_rng(rscript):
    # Fixed code only: no bundle text is executable and no relm is loaded.
    code = '''RNGkind("Mersenne-Twister", "Inversion", "Rejection")
cat("VERSION", as.character(getRversion()), sep=","); cat("\\n")
set.seed(1046); cat(c("SIGNS", sample(rep(c(-1L,1L),each=6L))), sep=","); cat("\\n")
set.seed(2046); b <- t(replicate(2000L,sample.int(8L,8L,replace=TRUE)))
write.table(b,stdout(),sep=",",row.names=FALSE,col.names=FALSE,quote=FALSE)
'''
    result = subprocess.run([rscript, "--vanilla", "-e", code], capture_output=True, timeout=30, check=False)
    require(result.returncode == 0, "model-free base-R RNG checker failed: " + result.stderr.decode("utf-8", errors="replace"))
    lines = list(csv.reader(io.StringIO(result.stdout.decode("utf-8"))))
    require(len(lines) == 2002 and lines[0][0] == "VERSION" and lines[1][0] == "SIGNS", "unexpected base-R RNG output")
    return lines[0][1], [int(x) for x in lines[1][1:]], [[int(x) for x in row] for row in lines[2:]]


def metric_values(text, pattern, token_count, finish_reason):
    lowered = text.lower()
    present = False
    for literal in pattern.split("|"):
        literal = literal.lower()
        require(bool(literal), "empty required literal")
        start = 0
        while True:
            offset = lowered.find(literal, start)
            if offset < 0: break
            end = offset + len(literal)
            if (offset == 0 or not lowered[offset - 1].isalnum()) and (end == len(lowered) or not lowered[end].isalnum()):
                present = True
                break
            start = offset + 1
    words = lowered.split()
    return dict(required=int(present), characters=len(text), tokens=token_count,
                empty=int(not text.strip()), truncated=int(finish_reason == "length"),
                repeated=sum(a == b for a, b in zip(words, words[1:])))


def inspect_events(raw, status, text):
    rows = csv_rows(raw, EVENT_COLUMNS)
    pieces, tokens, signature = [], [], []
    elapsed, terminal = 0., None
    for index, row in enumerate(rows, 1):
        require(integer(row["event_id"]) == index and row["prompt_id"] == "1", "stream event coordinates")
        current = number(row["elapsed"])
        require(current >= elapsed and row["validated"] == "", "stream elapsed/ordinary validation")
        elapsed = current
        require(terminal is None, "event after prompt_end")
        if row["event"] == "token":
            require(integer(row["token_pos"]) == len(tokens) + 1 and integer(row["token_id"]) > 0, "token order/ID")
            require(row["text"] == row["finish_reason"] == "", "token payload fields")
            tokens.append(integer(row["token_id"]))
        elif row["event"] == "text":
            require(bool(tokens), "text before any sampled token")
            require(row["token_pos"] == row["token_id"] == row["finish_reason"] == "" and bool(row["text"]), "text payload fields")
            pieces.append(row["text"])
        elif row["event"] == "prompt_end":
            require(row["token_pos"] == row["token_id"] == row["text"] == "", "finish payload fields")
            require(row["finish_reason"] in ("length", "stop", "context_full"), "unexpected finish reason/no stop strings")
            terminal = row["finish_reason"]
        else: raise VerificationError("unknown stream event")
        signature.append(tuple(row[key] for key in EVENT_COLUMNS if key != "elapsed"))
    require(len(tokens) <= 256, "sampled token cap exceeded")
    if status == "ok":
        require(terminal is not None and "".join(pieces) == text, "successful text/finish mismatch")
        require(terminal != "length" or len(tokens) == 256, "length finish without full sampled cap")
    else: require(terminal is None, "failed call published successful prompt_end")
    return tokens, terminal, signature, "".join(pieces)


def selected_coefficients(rows, manifest):
    indexed = {(row["item_id"], row["setting"]): row for row in rows}
    tasks = list(dict.fromkeys(row["item_id"] for row in rows))
    baseline = [indexed[(task, "baseline")] for task in tasks]
    require(len(tasks) == 6 and all(row["status"] == "ok" for row in baseline), "failed baseline invalidates selection")
    total = sum(row["metrics"]["characters"] for row in baseline)
    selections, table = {}, []
    for operator in ("add", "project"):
        eligible = []
        for coefficient in manifest[operator + "_coefficients"]:
            setting = operator + "_" + format(coefficient, "g")
            candidates = [indexed[(task, setting)] for task in tasks]
            successful = all(row["status"] == "ok" for row in candidates)
            quality = successful and all(c["metrics"]["required"] >= b["metrics"]["required"] and
                all(c["metrics"][key] <= b["metrics"][key] for key in ("empty", "truncated", "repeated"))
                for c, b in zip(candidates, baseline))
            characters = sum(row["metrics"]["characters"] for row in candidates) if successful else None
            admitted = quality and characters < total
            if admitted: eligible.append((characters, abs(coefficient), coefficient))
            table.append(dict(operator=operator, coefficient=coefficient, successful=successful,
                              quality_preserved=quality, total_characters=characters, eligible=admitted))
        selections[operator] = min(eligible)[2] if eligible else 0
    return selections, table


def quantile7(values, probability):
    ordered = sorted(values)
    location = (len(ordered) - 1) * probability
    lo = math.floor(location)
    fraction = location - lo
    return ordered[lo] + fraction * (ordered[min(lo + 1, len(ordered) - 1)] - ordered[lo])


def paired_intervals(rows, manifest, indices):
    indexed = {(row["item_id"], row["setting"]): row for row in rows}
    tasks = list(dict.fromkeys(row["item_id"] for row in rows))
    require(len(tasks) == 8, "final inference does not contain eight tasks")
    contrasts = [(setting, "baseline") for setting in manifest["final_settings"][1:]] + [("selected_project", "selected_add")]
    output = []
    for left, right in contrasts:
        pairs = [(indexed[(task, left)], indexed[(task, right)]) for task in tasks]
        missing = [task for task, (a, b) in zip(tasks, pairs) if a["status"] != "ok" or b["status"] != "ok"]
        for metric in METRICS:
            result = dict(setting=left, reference=right, metric=metric, n_tasks=8,
                          status="withheld" if missing else "descriptive", failed_tasks=missing,
                          differences=None, estimate=None, conf_low=None, conf_high=None)
            if not missing:
                differences = [a["metrics"][metric] - b["metrics"][metric] for a, b in pairs]
                resampled = [sum(differences[index - 1] for index in draw) / 8 for draw in indices]
                result.update(differences=differences, estimate=sum(differences) / 8,
                              conf_low=quantile7(resampled, .025), conf_high=quantile7(resampled, .975))
            output.append(result)
    return output


def verify_sources(bundle):
    data = bundle.data
    maps = []
    for key in ("sources_before", "sources_after"):
        rows = bundle.rows(data["files"][key], SOURCE_COLUMNS)
        mapping = {}
        for row in rows:
            name = row["source"]
            require(name and name not in mapping, "duplicate/empty source name")
            bundle.read({"file": row["snapshot_file"], "sha256": row["sha256"]})
            mapping[name] = row["sha256"]
        maps.append(mapping)
    require(maps[0] == maps[1], "execution source drift")
    mandatory = {
        "docs/f6e-evaluation-protocol.md": PROTOCOL_SHA,
        "tests/projection/evaluation/manifest.json": MANIFEST_SHA,
        "tests/projection/evaluation/prompts.csv": PROMPTS_SHA,
        "tests/projection/evaluation/verify_results.py": sha(Path(__file__).read_bytes()),
    }
    for path, checksum in mandatory.items(): require(maps[0].get(path) == checksum, "missing/wrong pinned source: " + path)
    producers = data["producer_sources"]
    require(type(producers) is list and producers and len(producers) == len(set(producers)) and
            any(name.endswith(".R") for name in producers), "missing executed R source")
    require(all(name in maps[0] for name in producers), "unbound producer source")
    return len(maps[0])


def verify_construction(bundle, prompts, signs):
    data = bundle.data
    original = [row for row in prompts if row["split"] == "construction"]
    captures = bundle.rows(data["files"]["construction"], CONSTRUCTION_COLUMNS)
    require(len(captures) == 24, "missing construction trace")
    indexed = {}
    paths = set()
    for row, expected in zip(captures, original):
        require(all(row[key] == expected[key] for key in ("item_id", "role", "prompt_sha256")), "construction leakage/order/provenance")
        require(integer(row["source_pos"]) > 0, "invalid actual trace source position")
        require(row["capture_file"] not in paths, "reused construction capture file")
        paths.add(row["capture_file"])
        bundle.read({"file": row["capture_file"], "sha256": row["capture_sha256"]})
        indexed[(row["item_id"], row["role"])] = row
    pairs = bundle.rows(data["files"]["artifact_pairs"], PAIR_COLUMNS)
    names = list(dict.fromkeys(row["item_id"] for row in original))
    require(len(pairs) == 36, "artifact pair count")
    for row, (artifact, pair) in zip(pairs, [(a, p) for a in ("residual", "mlp", "random_mlp") for p in names]):
        require(row["artifact"] == artifact and row["item_id"] == pair, "artifact construction order/leakage")
        roles = ("control", "target") if artifact == "random_mlp" and signs[names.index(pair)] == -1 else ("target", "control")
        for output_role, source_role in zip(("target", "control"), roles):
            source = indexed[(pair, source_role)]
            require(row[output_role + "_sha256"] == source["prompt_sha256"] and
                    row[output_role + "_pos"] == source["source_pos"], "untruthful random/learned pair roles or positions")
    return names


def setting_spec(setting, selected):
    if setting == "baseline": return "none", 0., ""
    if setting == "random_project_1": return "project", 1., "random_mlp"
    if setting in ("zero_add", "zero_project"):
        operator = setting.removeprefix("zero_")
        return operator, 0., "residual" if operator == "add" else "mlp"
    if setting in ("selected_add", "selected_project"):
        operator = setting.removeprefix("selected_")
        require(selected is not None, "selected setting before coefficient lock")
        return operator, selected[operator], "residual" if operator == "add" else "mlp"
    operator, coefficient = setting.split("_", 1)
    require(operator in ("add", "project"), "unknown setting")
    return operator, number(coefficient), "residual" if operator == "add" else "mlp"


def verify_runs(bundle, phase, expected, selected, lock_sha, previous_end, paths):
    raw = bundle.rows(bundle.data["files"][{"selection": "selection", "evaluation": "evaluation", "view": "views"}[phase]], RUN_COLUMNS)
    require(len(raw) == len(expected), "missing/extra " + phase + " runs")
    output = []
    for row, (ordinal, run_id, prompt, setting) in zip(raw, expected):
        require(integer(row["ordinal"]) == ordinal and row["run_id"] == run_id and row["phase"] == phase,
                "duplicate/missing/reordered run")
        require(row["item_id"] == prompt["item_id"] and row["prompt_sha256"] == prompt["prompt_sha256"] and row["setting"] == setting,
                "task/setting order or prompt leakage")
        operator, coefficient, artifact = setting_spec(setting, selected)
        require(row["operator"] == operator and number(row["coefficient"]) == coefficient and row["artifact"] == artifact,
                "coefficient/operator/artifact retuned")
        expected_artifact = bundle.data["artifacts"][artifact]["sha256"] if artifact else ""
        require(row["artifact_sha256"] == expected_artifact, "wrong direction artifact")
        require(row["request_seed"] == "1046" and row["chat"] == "FALSE" and number(row["temperature"]) == 0. and
                number(row["top_p"]) == .95 and row["max_tokens"] == "256" and row["watchdog_seconds"] == "120" and
                all(row[key] == "TRUE" for key in ("stop_is_null", "images_is_null", "schema_is_null", "async")) and
                row["on_state"] == ("TRUE" if phase == "view" else "FALSE"), "generation settings changed")
        require(row["selection_lock_sha256"] == lock_sha, "missing/wrong pre-final lock binding")
        start, end, elapsed = [number(row[key]) for key in ("started_unix", "ended_unix", "elapsed_seconds")]
        require(0 <= start <= end and start >= previous_end and elapsed >= 0., "overlap/time order/elapsed")
        previous_end = end
        require(row["status"] in ("ok", "error", "cancelled", "timed_out"), "unknown result status")
        status = row["status"]
        text, error = None, None
        for field in ("text_file", "events_file", "error_file"):
            if row[field]:
                require(row[field] not in paths, "reused raw file across distinct calls")
                paths.add(row[field])
        if status == "ok":
            require(row["returned_seed"] == "1046" and row["error_file"] == row["error_sha256"] == "", "success seed/error metadata")
            try: text = bundle.read({"file": row["text_file"], "sha256": row["text_sha256"]}).decode("utf-8", errors="strict")
            except UnicodeError as caught: raise VerificationError("invalid returned UTF8") from caught
            require("\x00" not in text, "NUL returned string")
        else:
            require(row["returned_seed"] == row["text_file"] == row["text_sha256"] == "", "failed call has invented successful return")
            errors = bundle.rows({"file": row["error_file"], "sha256": row["error_sha256"]}, ["class", "reason", "message"])
            require(len(errors) == 1 and errors[0]["class"] and errors[0]["message"], "missing raw condition")
            error = errors[0]
        tokens, finish, signature, partial = inspect_events(bundle.read({"file": row["events_file"], "sha256": row["events_sha256"]}), status, text)
        metrics = metric_values(text, prompt["required_pattern"], len(tokens), finish) if status == "ok" else None
        output.append(dict(run_id=run_id, ordinal=ordinal, item_id=row["item_id"], setting=setting,
            operator=operator, coefficient=coefficient, artifact=artifact, status=status, metrics=metrics,
            elapsed_seconds=elapsed, started_unix=start, ended_unix=end, finish_reason=finish,
            observed_tokens=len(tokens), partial_characters=len(partial), error=error,
            prompt_sha256=row["prompt_sha256"], text=text, token_ids=tokens, signature=signature))
    return output, previous_end


def check_zeros(rows, allow_failed=False):
    unavailable = []
    indexed = {(row["item_id"], row["setting"]): row for row in rows}
    for task in dict.fromkeys(row["item_id"] for row in rows):
        baseline = indexed[(task, "baseline")]
        for setting in ("zero_add", "zero_project"):
            zero = indexed[(task, setting)]
            if allow_failed and (zero["status"] != "ok" or baseline["status"] != "ok"):
                unavailable.append(task + "/" + setting)
                continue
            require(zero["status"] == baseline["status"] == "ok" and zero["text"] == baseline["text"] and
                    zero["signature"] == baseline["signature"], "zero identity engineering failure: " + task + "/" + setting)
    return unavailable


def summarize(rows):
    result = []
    for setting in dict.fromkeys(row["setting"] for row in rows):
        items = [row for row in rows if row["setting"] == setting]
        good = [row for row in items if row["status"] == "ok"]
        result.append(dict(setting=setting, tasks=len(items), succeeded=len(good), failed=len(items) - len(good),
            truncated=sum(row["metrics"]["truncated"] for row in good),
            untruncated=sum(not row["metrics"]["truncated"] for row in good),
            context_full=sum(row["finish_reason"] == "context_full" for row in good)))
    return result


def report_rows(rows):
    return [{key: value for key, value in row.items() if key not in ("signature", "text", "token_ids")}
            for row in rows]


def verify_views(bundle, views):
    rows = bundle.rows(bundle.data["files"]["view_states"], STATE_COLUMNS)
    require(len(rows) == 4, "expected four retained view states")
    prefixes = {}
    for row, (view, state) in zip(rows, [(view, state) for view in views for state in (1, 2)]):
        require(row["run_id"] == view["run_id"] and integer(row["state_id"]) == state, "view state order/count")
        require(view["status"] == "cancelled" and len(view["token_ids"]) == 1 and
                "relm_error_cancelled" in view["error"]["class"].split(";") and view["error"]["reason"] == "requested", "two-state view cancellation outcome")
        count, source, token = [integer(row[key]) for key in ("prompt_token_count", "source_pos", "source_token_id")]
        require(count > 0 and source == count + state - 1 and token > 0, "view source position")
        expected = "" if state == 1 else str(view["token_ids"][0])
        require(row["generated_prefix_ids"] == expected and (state == 1 or token == view["token_ids"][0]), "view prefix not actual streamed tokens")
        bundle.read({"file": row["state_file"], "sha256": row["state_sha256"]})
        prefixes[(view["run_id"], state)] = (view["prompt_sha256"], count, source, token, expected)
    alignment = [prefixes[(views[0]["run_id"], state)] == prefixes[(views[1]["run_id"], state)] for state in (1, 2)]
    require(alignment[0], "first construction view source is not aligned")
    return dict(calls=2, retained_states=4, aligned_state_ids=[i + 1 for i, same in enumerate(alignment) if same],
                unaligned_state_ids=[i + 1 for i, same in enumerate(alignment) if not same], efficacy_included=False,
                rds_contents_verified=False)


def verify_bundle(directory, stage, rscript="Rscript"):
    require(stage in ("selection", "complete"), "unknown verification stage")
    manifest, prompts = pinned_inputs()
    bundle = Bundle(directory)
    data = bundle.data
    exact_fields(data, SCHEMA["receipt_exact_fields"], "receipt")
    require(data["schema"] == SCHEMA_VERSION and data["protocol_sha256"] == PROTOCOL_SHA and
            data["manifest_sha256"] == MANIFEST_SHA and data["prompts_sha256"] == PROMPTS_SHA, "protocol identity changed")
    exact_fields(data["identity"], SCHEMA["identity_exact_fields"], "identity")
    identity = data["identity"]
    require(identity["model_sha256"] == MODEL_SHA and identity["backend"] == "cpu" and
            type(identity["context_length"]) is int and identity["context_length"] == 512 and
            type(identity["layer"]) is int and identity["layer"] == 12, "wrong model/backend/site/context")
    for key in ("package_version", "engine_revision", "source_revision", "r_version"):
        require(type(identity[key]) is str and bool(identity[key]), "missing runtime identity")
    require(re.fullmatch(r"[0-9a-f]{40}", identity["source_revision"]) and re.fullmatch(r"[0-9a-f]{64}", identity["dll_sha256"]), "source/DLL digest format")
    cpu = read_json(bundle.read(identity["cpu_evidence"]))
    require(cpu.get("backend") == "cpu" and type(cpu.get("n_gpu_layers")) is int and cpu.get("n_gpu_layers") == 0 and cpu.get("model_sha256") == MODEL_SHA, "CPU evidence mismatch")
    bundle.read(identity["installed_evidence"])
    require(data["rng"] == SCHEMA["rng_exact_fields"], "R RNG specification changed")
    exact_fields(data["files"], FILE_KEYS, "files")
    exact_fields(data["artifacts"], ["residual", "mlp", "random_mlp"], "artifacts")
    for descriptor in data["artifacts"].values(): bundle.read(descriptor)
    source_count = verify_sources(bundle)
    r_version, expected_signs, expected_bootstrap = real_r_rng(rscript)
    require(r_version == identity["r_version"], "base-R checker version differs from producer")
    names = [row["item_id"] for row in prompts if row["split"] == "construction" and row["role"] == "target"]
    sign_rows = bundle.rows(data["files"]["random_signs"], ["item_id", "sign"])
    require([row["item_id"] for row in sign_rows] == names, "random sign pair order")
    signs = [integer(row["sign"]) for row in sign_rows]
    require(signs == expected_signs and signs.count(-1) == signs.count(1) == 6, "R seed1046 balanced signs differ")
    verify_construction(bundle, prompts, signs)
    index_rows = bundle.rows(data["files"]["bootstrap"], SCHEMA["bootstrap_columns"])
    require(len(index_rows) == 2000 and [integer(row["replicate"]) for row in index_rows] == list(range(1, 2001)), "bootstrap replicate count/order")
    indices = [[integer(row[f"draw{i}"]) for i in range(1, 9)] for row in index_rows]
    require(indices == expected_bootstrap and all(1 <= index <= 8 for draw in indices for index in draw), "saved bootstrap differs from real R seed2046")
    tasks = [row for row in prompts if row["split"] == "selection"]
    expected = [(i + 1, f"s{i + 1:03}", task, setting) for i, (task, setting) in
                enumerate((task, setting) for task in tasks for setting in manifest["selection_settings"])]
    paths = set()
    selection, previous_end = verify_runs(bundle, "selection", expected, None, "", 0., paths)
    check_zeros(selection)
    selected, eligibility = selected_coefficients(selection, manifest)
    evidence = sha(canonical(dict(schema="F6e-selection-evidence/1", identity=identity, rng=data["rng"],
        producer_sources=data["producer_sources"], artifacts=data["artifacts"],
        files=[dict(file=name, sha256=checksum) for name, checksum in sorted(bundle.used.items())])))
    report = dict(schema="F6e-verification/1", stage=stage, status="verified_receipts", protocol="F6e-v1",
        verifier_sha256=sha(Path(__file__).read_bytes()), source_files=source_count,
        selected=selected, eligibility=eligibility, selection_evidence_sha256=evidence,
        selection=report_rows(selection), selection_counts=summarize(selection),
        observations=72, verified_files=len(bundle.used), scientific_claim="small fixed convenience corpus; no population/multiplicity or isolated-operator claim",
        limitations=["File/source/runtime records are evidence binding, not execution or loaded-weight authentication.",
                     "Opaque artifact/capture/state RDS arithmetic and graphics require their separate owner gates.",
                     "Literal inclusion is not reasoning/factuality/safety validation; length caps may truncate answers."])
    if stage == "selection":
        require(all(data["files"][key] is None for key in ("evaluation", "views", "view_states", "selection_lock")), "selection stage already contains final/view/lock evidence")
    else:
        lock = read_json(bundle.read(data["files"]["selection_lock"]))
        exact_fields(lock, SCHEMA["selection_lock_exact_fields"], "selection lock")
        require(type(lock["selected_add"]) in (int, float) and type(lock["selected_project"]) in (int, float), "coefficient lock types")
        require(lock["schema"] == "F6e-selection-lock/1" and lock["selected_add"] == selected["add"] and
                lock["selected_project"] == selected["project"] and lock["selection_evidence_sha256"] == evidence and
                lock["verifier_sha256"] == report["verifier_sha256"], "selection lock retuned or inputs changed")
        frozen = read_json(bundle.read(lock["selection_report"]))
        expected_frozen = dict(report, stage="selection")
        require(frozen == expected_frozen, "selection report was not the independent pre-final computation")
        lock_time = number(lock["locked_at_unix"])
        require(lock_time >= previous_end, "selection locked before all selection calls")
        tasks = [row for row in prompts if row["split"] == "evaluation"]
        expected = [(i + 73, f"e{i + 1:03}", task, setting) for i, (task, setting) in
                    enumerate((task, setting) for task in tasks for setting in manifest["final_settings"])]
        final, previous_end = verify_runs(bundle, "evaluation", expected, selected, data["files"]["selection_lock"]["sha256"], lock_time, paths)
        # Failed calls remain in the fixed sample. Baseline/zero errors also
        # leave an explicit unresolved engineering identity requirement.
        zero_unavailable = check_zeros(final, allow_failed=True)
        prompt = next(row for row in prompts if row["item_id"] == "f6e-c01" and row["role"] == "target")
        expected = [(121, "v001", prompt, "baseline"), (122, "v002", prompt, "selected_project")]
        views, previous_end = verify_runs(bundle, "view", expected, selected, data["files"]["selection_lock"]["sha256"], previous_end, paths)
        report.update(observations=122, evaluation=report_rows(final), evaluation_counts=summarize(final),
                      zero_identity=dict(status="unresolved_error" if zero_unavailable else "passed", unavailable=zero_unavailable),
                      intervals=paired_intervals(final, manifest, indices), views=verify_views(bundle, views),
                      view_runs=report_rows(views))
    report["verified_files"] = len(bundle.used)
    # This field is added only after report/lock comparisons; it is deterministic
    # for a fixed stage and is also part of the stored selection report.
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--schema", action="store_true")
    parser.add_argument("--stage", choices=("selection", "complete"))
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--rscript", default="Rscript")
    args = parser.parse_args()
    if args.schema:
        require(args.stage is None and args.bundle is None and args.output is None, "schema mode takes no bundle")
        print(json.dumps(SCHEMA, indent=2))
        return
    require(args.stage and args.bundle and args.output, "stage, bundle and fresh output are required")
    require(not args.output.exists(), "refusing to overwrite verification report")
    report = verify_bundle(args.bundle, args.stage, args.rscript)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    print(f"F6E_EVALUATION_VERIFIED stage={args.stage} observations={report['observations']} sources={report['source_files']} files={report['verified_files']}")


if __name__ == "__main__":
    try: main()
    except (VerificationError, OSError, subprocess.SubprocessError) as error:
        print("F6E_EVALUATION_FAILED " + str(error), file=sys.stderr)
        raise SystemExit(1)
