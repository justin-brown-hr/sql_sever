#!/usr/bin/env python3
"""Check runner modes without a database; record files passed to a mock sqlcmd."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='upr-runner-') as tmp:
    folder = Path(tmp)
    log = folder / 'calls'
    fake = folder / 'sqlcmd'
    fake.write_text('#!/bin/bash\nwhile [[ $# -gt 0 ]]; do\n'
                    '  if [[ "$1" == "-i" ]]; then shift; echo "$1" >> "$UPR_RUNNER_TEST_LOG"; fi\n'
                    '  shift\ndone\n')
    fake.chmod(0o755)
    env = dict(os.environ, PATH=str(folder) + os.pathsep + os.environ['PATH'],
               UPR_RUNNER_TEST_LOG=str(log))
    for mode in (None, '--real-data', '--sample-data', '--real_data'):
        log.write_text('')
        args = ['bash', str(ROOT / 'scripts/run_all.sh'), 'test-server', 'test-user', '']
        if mode is not None:
            args.append(mode)
        result = subprocess.run(args, env=env, capture_output=True, text=True)
        calls = log.read_text().splitlines()
        if mode == '--real_data':
            assert result.returncode == 2 and not calls, (result, calls)
        else:
            assert result.returncode == 0, result.stderr
            assert any(p.endswith('scripts/load_upr_master.sql') for p in calls), calls
            destructive = [p for p in calls if '/ddl/' in p or p.endswith('local_it_setup.sql')]
            assert len(destructive) == (2 if mode == '--sample-data' else 0), (mode, calls)
        print('PASS: runner mode', mode or '(default)')
