"""Collect only bound affected-review regression receipts; import has no execution."""
import json
import re


def unique(pairs):
    result = {}
    for key, value in pairs:
        assert key not in result, 'duplicate JSON field'
        result[key] = value
    return result


def equal(actual, expected):
    assert type(actual) is type(expected), 'marker type mismatch'
    if isinstance(expected, dict):
        assert set(actual) == set(expected), 'marker field mismatch'
        for key in expected:
            equal(actual[key], expected[key])
    elif isinstance(expected, list):
        assert len(actual) == len(expected), 'marker list length'
        for a, e in zip(actual, expected):
            equal(a, e)
    else:
        assert actual == expected, 'marker value mismatch'


def native(log, spec):
    exact = spec['id']
    assert re.findall(r'^running (\d+) tests?$', log, re.M) == ['1'], 'one test required'
    assert re.findall(r'^test ([^ ]+) \.\.\. ', log, re.M) == [exact], 'exact test name'
    counts = re.findall(r'^test result: ok\. (\d+) passed; (\d+) failed; (\d+) ignored; (\d+) measured; (\d+) filtered out;', log, re.M)
    assert len(counts) == 1 and counts[0][:4] == ('1', '0', '0', '0'), 'positive libtest outcome'
    assert re.search(r'^(?:ok|test '+re.escape(exact)+r' \.\.\. ok)$', log, re.M), 'test completion'
    assert not re.search(r'^(?:warning(?:\[|:)|error(?:\[|:)|test result: FAILED|ld: warning:)', log, re.M), 'compiler/linker/test diagnostic'
    prefix = spec['marker'] + ' '
    hits = []
    for line in log.splitlines():
        named = 'test ' + exact + ' ... '
        if line.startswith(named):
            line = line[len(named):]
        if line.startswith(prefix):
            hits.append(line[len(prefix):])
    assert len(hits) == 1, 'one marker required'
    receipt = json.loads(hits[0], object_pairs_hook=unique,
                         parse_constant=lambda value: (_ for _ in ()).throw(AssertionError('nonfinite JSON')))
    equal(receipt, spec['expected_marker'])
    return receipt
