#!/usr/bin/env python3
"""Offline WP12a consistency gate; never starts a service or certifies runtime."""
import argparse
import copy
import csv
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def require(value, message):
    if not value:
        raise ValueError(message)


def validate(contract, pins):
    require(contract['status'] == 'approved', 'D-034 approval state changed')
    require(contract['decision'] == 'D-034', 'wrong decision')
    require(contract['bind']['host'] == '127.0.0.1' and
            not contract['bind']['browser_origins'], 'local access scope changed')
    limits = contract['limits']
    require(all(type(v) is int and v >= 0 for v in limits.values()), 'limits must be finite nonnegative integers')
    require(limits['active_requests'] == 1 and limits['queued_requests'] == 0,
            'single worker / zero queue invariant changed')
    require(limits['request_body_bytes'] > limits['document_text_bytes'] > limits['target_bytes'],
            'payload budgets must leave room for metadata')
    require(limits['output_tokens'] < limits['context_tokens'], 'no prompt headroom')
    require(0 < limits['overflow_prefix_bytes'] < limits['raw_output_bytes'], 'overflow prefix must be bounded')
    require(6 * limits['overflow_prefix_bytes'] + limits['overflow_metadata_bytes'] <= limits['terminal_record_bytes'],
            'fallback cannot fit worst-case JSON escaping')
    require(0 < limits['diagnostic_drain_bytes_per_tick'] <= limits['worker_diagnostic_bytes'] < limits['epoch_ipc_bytes'],
            'diagnostics/IPC budgets inconsistent')
    require(limits['recovery_seconds'] >= limits['worker_start_seconds'] + limits['worker_death_seconds'],
            'recovery excludes worker death or startup')
    require(limits['stop_seconds'] >= limits['graceful_drain_seconds'] + limits['worker_death_seconds'],
            'stop excludes drain/death')
    require(limits['native_stress_requests'] == 1000, 'native stress gate weakened')
    require(limits['stress_warmup_requests'] + limits['stress_tail_requests'] < limits['native_stress_requests'],
            'memory windows overlap')
    require(limits['store_admission_floor_bytes'] > limits['terminal_record_bytes'], 'insufficient write headroom')
    terminal = set(contract['accepted_terminal_states'])
    require(terminal == {'success', 'invalid', 'error', 'interrupted'}, 'terminal accounting incomplete')
    edges = contract['allowed_transitions']
    states = set(contract['request_states'])
    require(all(len(e) == 2 and e[0] in states and e[1] in states and e[0] not in terminal for e in edges),
            'terminal records cannot transition or be retried')
    require({e[1] for e in edges} >= terminal, 'unreachable terminal result')
    require(contract['http']['busy'] == 429 and contract['http']['changed_replay'] == 409,
            'overload/conflict policy changed')
    require(set(contract['request_fields']) == {'id', 'target', 'text', 'seed'}, 'request surface drift')
    required = {'one_frontend_writer', 'one_live_model_worker', 'no_request_queue',
                'admission_before_dispatch', 'terminal_before_visibility',
                'no_automatic_replay', 'dead_worker_before_replacement',
                'late_worker_epoch_discarded', 'native_handles_never_cross_processes',
                'serialized_terminal_size_checked', 'private_epoch_ipc',
                'dead_worker_before_epoch_cleanup'}
    require(required <= set(contract['invariants']), 'ownership/persistence guard missing')
    gates = contract['future_runtime_gates']
    require([g['id'] for g in gates] == [f'G{i}' for i in range(1, 9)], 'acceptance gate omitted')
    require(all(g['status'] == 'not_run' and g['owner'] and g['fixture'] for g in gates),
            'planned runtime execution must not be reported as passed')
    require(set(contract['profiles']) == {'mac_spark', 'mac_qwen', 'linux_qwen'}, 'required hardware profile absent')
    require(contract['profiles']['linux_qwen']['backend'] == 'cpu', 'Linux acceptance backend drift')
    names = [p['package'] for p in pins]
    require(len(names) == len(set(names)) == 23, 'dependency closure is missing or duplicated')
    require(all(re.fullmatch(r'[0-9]+(?:[.-][0-9]+)+', p['version']) for p in pins), 'unpinned dependency')
    direct = {p['package']: p['version'] for p in pins if p['role'] == 'direct'}
    require(direct == {'plumber': '1.3.3', 'callr': '3.8.0', 'later': '1.4.8',
                       'httpuv': '1.6.17', 'ps': '1.9.3', 'jsonlite': '2.0.0'}, 'direct proposal drift')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    contract = json.loads((HERE / 'contract.json').read_text())
    pins = list(csv.DictReader((HERE / 'dependencies.csv').open()))
    validate(contract, pins)
    # Contract arithmetic examples, not an implementation of the R serializer.
    limits = contract['limits']
    escaped_raw = '\x01' * limits['raw_output_bytes']
    require(len(json.dumps({'raw': escaped_raw}).encode()) > limits['terminal_record_bytes'],
            'adversarial example must exercise serialized overflow')
    escaped_prefix = '\x01' * limits['overflow_prefix_bytes']
    # Metadata budget includes keys/framing, so this string literal is conservative.
    require(len(json.dumps(escaped_prefix).encode()) + limits['overflow_metadata_bytes'] <= limits['terminal_record_bytes'],
            'fallback example exceeds terminal budget')
    provenance = json.loads((HERE / 'dependency-provenance.json').read_text())
    require(hashlib.sha256((HERE / 'dependencies.csv').read_bytes()).hexdigest() == provenance['dependency_csv_sha256'],
            'dependency CSV differs from its captured provenance')
    for document in (ROOT / 'docs/service-contract.md', HERE / 'README.md'):
        for target in re.findall(r'\]\(([^)]+)\)', document.read_text()):
            if not target.startswith(('https://', '#')):
                require((document.parent / target.split('#')[0]).exists(), f'broken local link: {target}')
    docs = json.loads((ROOT / 'examples/funding-extraction/documents.json').read_text())
    require(len(docs) == 3, 'development fixture changed; reconsider workload explicitly')
    for doc in docs:
        require(set(doc) == set(contract['request_fields']), 'D2 fixture/request shape mismatch')
        for key, limit in [('id', 'request_id_bytes'), ('text', 'document_text_bytes'), ('target', 'target_bytes')]:
            require(len(doc[key].encode('utf-8')) <= contract['limits'][limit], 'D2 fixture exceeds service limit')
        require(len(json.dumps(doc).encode()) <= contract['limits']['request_body_bytes'], 'D2 request exceeds HTTP limit')
    mutations = []
    if args.self_test:
        for name, mutate in [
            ('queue', lambda c: c['limits'].update(queued_requests=1)),
            ('workers', lambda c: c['limits'].update(active_requests=2)),
            ('public_bind', lambda c: c['bind'].update(host='0.0.0.0')),
            ('short_stress', lambda c: c['limits'].update(native_stress_requests=100)),
            ('impossible_recovery', lambda c: c['limits'].update(recovery_seconds=1)),
            ('terminal_retry', lambda c: c['allowed_transitions'].append(['success', 'running'])),
            ('missing_interruption', lambda c: c['accepted_terminal_states'].remove('interrupted')),
            ('false_runtime_pass', lambda c: c['future_runtime_gates'][0].update(status='passed')),
            ('oversized_fallback', lambda c: c['limits'].update(overflow_prefix_bytes=65535)),
            ('shared_ipc', lambda c: c['invariants'].remove('private_epoch_ipc')),
            ('unbounded_diagnostics', lambda c: c['limits'].update(diagnostic_drain_bytes_per_tick=67108864)),
        ]:
            bad = copy.deepcopy(contract)
            mutate(bad)
            try:
                validate(bad, pins)
            except ValueError:
                mutations.append(name)
            else:
                raise AssertionError(f'mutation accepted: {name}')
    print(f'PASS: offline contract consistency; {len(pins)} dependency pins; {len(docs)} D2 inputs fit; JSON overflow bounds checked; '
          f'{len(mutations)} deliberate mutations rejected. Runtime acceptance is reported separately.')


if __name__ == '__main__':
    main()
