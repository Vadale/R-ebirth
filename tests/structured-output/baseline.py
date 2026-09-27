#!/usr/bin/env python3
"""Frozen abstention and first-amount baselines; no model, tuning or dependencies."""
import copy
import json
import re
from decimal import Decimal
from verify import ROOT, FIELDS, audit, evaluate, loads


def missing():
    return dict(amount_usd=None, amount_qualifier="not_stated", duration_years=None,
                conditional_on_funds=None, evidence=dict.fromkeys(FIELDS))


def first_amount(case):
    # Intentionally ignores requested target/scope; exposes that baseline's cost.
    out, text = missing(), case["text"]
    money = re.search(r"(?:(about|approximately|roughly|nearly|up to|at least|more than) )?\$(\d+(?:\.\d+)?)\s*(million|billion)?", text, re.I)
    if money:
        scale = {None: 1, "million": 1000000, "billion": 1000000000}[money[3].lower() if money[3] else None]
        amount = Decimal(money[2]) * scale
        if amount == amount.to_integral_value() and 0 <= amount <= 2147483647:
            out["amount_usd"] = int(amount)
            out["amount_qualifier"] = {None: "stated", "about": "approximate", "approximately": "approximate", "roughly": "approximate", "nearly": "less_than", "up to": "at_most", "at least": "at_least", "more than": "more_than"}[money[1].lower() if money[1] else None]
            out["evidence"]["amount_usd"] = money[0].strip()
            out["evidence"]["amount_qualifier"] = money[0].strip()
    period = re.search(r"(?:over|for) (?:the next )?(one|two|three|four|five|\d+)(?:-| )year(?:s| period)?", text, re.I)
    if period:
        words = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5}
        years = words.get(period[1].lower()) or int(period[1])
        if 1 <= years <= 30:
            out["duration_years"] = years
            out["evidence"]["duration_years"] = period[0]
    return out


cases = loads((ROOT / "cases.json").read_text())
audit(cases, loads((ROOT / "manifest.json").read_text()))
report = {}
for split in ["development", "held_out", "contract"]:
    selected = [c for c in cases if c["split"] == split]
    report[split] = {}
    for name, predict in [("always_missing", lambda _: missing()), ("first_amount", first_amount)]:
        rows = [dict(id=c["id"], status="success", output=copy.deepcopy(predict(c))) for c in selected]
        report[split][name] = evaluate(selected, rows)
print(json.dumps(report, indent=2))
