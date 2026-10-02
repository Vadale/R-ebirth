import json, pathlib, subprocess, time, hashlib, sys
repo = pathlib.Path('/Users/alessandrovadala/DOCUDESK/R-ebirth')
source = pathlib.Path('/private/tmp/relm-i1/native-client-02')
root = pathlib.Path('/private/tmp/relm-i1/replay-reviewed-01')
root.mkdir(exist_ok=False)
status = dict(state='running', started=time.time(), results=[])
def save():
    tmp = root / 'status.tmp'
    tmp.write_text(json.dumps(status, indent=2) + '\n')
    tmp.replace(root / 'status.json')
save()
try:
    for case, original in [('longitudinal', 'analysis-deliverables'), ('insufficient', 'final-analysis'), ('missing_package', 'analysis-output'), ('fit_warning', 'analysis-output'), ('guided', 'analysis-output-final')]:
        status['active_case'] = case
        save()
        work = source / case
        output = root / case
        input_file = work / ('prompt.txt' if case == 'missing_package' else 'observations.csv')
        command = ['Rscript', '--vanilla', str(repo / 'integrations/skills/r-statistical-analysis/scripts/run-analysis.R'), str(work / 'analysis.R'), str(output), str(input_file)]
        with (root / (case + '.log')).open('w') as log:
            run = subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        comparisons = {p.name: p.read_bytes() == (output / p.name).read_bytes() for p in (work / original).glob('*.csv') if p.name != 'manifest.csv'}
        result = dict(case=case, exit_code=run.returncode, source_sha256=hashlib.sha256((work/'analysis.R').read_bytes()).hexdigest(), numerical_files_equal=comparisons)
        status['results'].append(result)
        save()
        if run.returncode or not all(comparisons.values()):
            raise RuntimeError('Replay mismatch: ' + case)
    work = source / 'python'
    run = subprocess.run([sys.executable, str(work/'analyze_group_means.py'), str(work/'observations.csv'), str(root/'python.csv')], capture_output=True, text=True, timeout=30)
    (root/'python.log').write_text(run.stdout + run.stderr)
    equal = (root/'python.csv').read_bytes() == (work/'group_mean_outcomes.csv').read_bytes()
    status['results'].append(dict(case='python', exit_code=run.returncode, numerical_files_equal={'group_mean_outcomes.csv':equal}))
    if run.returncode or not equal:
        raise RuntimeError('Python replay mismatch')
    status.update(state='passed', finished=time.time(), active_case=None)
except Exception as error:
    status.update(state='failed', error=str(error), finished=time.time())
save()
