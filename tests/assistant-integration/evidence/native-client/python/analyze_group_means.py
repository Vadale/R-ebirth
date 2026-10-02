#!/usr/bin/env python3
"""Compute the observed mean outcome for each group in a CSV file."""

import argparse
import csv
from collections import defaultdict
from decimal import Decimal, InvalidOperation, localcontext
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compute descriptive group means from observations.csv."
    )
    parser.add_argument(
        "input_csv",
        nargs="?",
        type=Path,
        default=Path("observations.csv"),
        help="Input CSV path (default: observations.csv)",
    )
    parser.add_argument(
        "output_csv",
        nargs="?",
        type=Path,
        default=Path("group_mean_outcomes.csv"),
        help="Output CSV path (default: group_mean_outcomes.csv)",
    )
    return parser.parse_args()


def compute_group_means(input_csv: Path) -> list[tuple[str, int, Decimal]]:
    totals: dict[str, Decimal] = defaultdict(Decimal)
    counts: dict[str, int] = defaultdict(int)

    with input_csv.open("r", encoding="utf-8", newline="") as source:
        reader = csv.DictReader(source)
        required_columns = {"group", "outcome"}
        missing_columns = required_columns.difference(reader.fieldnames or [])
        if missing_columns:
            missing = ", ".join(sorted(missing_columns))
            raise ValueError(f"Missing required column(s): {missing}")

        for line_number, row in enumerate(reader, start=2):
            group = (row["group"] or "").strip()
            outcome_text = (row["outcome"] or "").strip()
            if not group:
                raise ValueError(f"Blank group at CSV line {line_number}")
            try:
                outcome = Decimal(outcome_text)
            except InvalidOperation as error:
                raise ValueError(
                    f"Invalid outcome at CSV line {line_number}: {outcome_text!r}"
                ) from error
            if not outcome.is_finite():
                raise ValueError(
                    f"Non-finite outcome at CSV line {line_number}: {outcome_text!r}"
                )
            totals[group] += outcome
            counts[group] += 1

    if not counts:
        raise ValueError("The input CSV contains no observations")

    with localcontext() as context:
        context.prec = 28
        return [
            (group, counts[group], totals[group] / counts[group])
            for group in sorted(counts)
        ]


def write_results(
    output_csv: Path, results: list[tuple[str, int, Decimal]]
) -> None:
    with output_csv.open("w", encoding="utf-8", newline="") as destination:
        writer = csv.writer(destination, lineterminator="\n")
        writer.writerow(["group", "observation_count", "mean_outcome"])
        for group, count, mean in results:
            writer.writerow([group, count, format(mean, ".6f")])


def main() -> None:
    args = parse_args()
    results = compute_group_means(args.input_csv)
    write_results(args.output_csv, results)


if __name__ == "__main__":
    main()
