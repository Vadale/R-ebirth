# Captured parent callback condition

The targeted unchanged case reproduced the failure. The parent is a testthat
expectation_failure: the actual scalar is exactly 0.125 with the matrix row name
`1.30`, while the expected scalar is unnamed. The public trace intentionally
labels rows as prompt_id.token_pos. No missing capture, numerical defect or
steering failure was established. The correction checks the row label explicitly
and compares the unnamed scalar with identical(), retaining exact numeric/type
comparison. No production source, deadline, tolerance or installed binary changes.
