"""Exercise the actual Roc formatter process; no third-party packages required."""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--roc', default='roc')
parser.add_argument('--specialize', choices=['yes', 'no'], default='yes')
args = parser.parse_args()
formatter = Path(__file__).resolve().parents[1] / 'json-repl-formatter.roc'

requests = [
    {'code': 'x = 40.I64'},
    {'code': 'x + 2'},
    {'code': 'y = 3.I64\nx + y'},
    {'code': '"café 🌍 \\"quote\\""'},
    {'code': '{\n dbg "hello"\n x + 4\n}'},
    {'code': 'unknown_name'},
    {'code': 'x + 5'},
    '{bad json',
    {'no_code': True},
    {'code': 12},
    {'code': ''},
    {'code': '"' + 'a' * 300_000 + '"'},
    {'code': 'x'},
    {'code': 'crash "cell failure"'},
    {'code': 'x + 6'},
]
wire = '\n'.join(x if isinstance(x, str) else json.dumps(x, ensure_ascii=False) for x in requests)
# Intentionally omit the last delimiter to exercise EOF framing.
run = subprocess.run([args.roc, 'repl', '--specialize=' + args.specialize, '--formatter', str(formatter)], input=wire,
                     text=True, capture_output=True, timeout=180)
assert run.returncode == 0, run.stderr
replies = [json.loads(line) for line in run.stdout.splitlines()]
assert len(replies) == len(requests), (len(replies), run.stderr)
for reply in replies:
    assert set(reply) == {'result', 'stdout', 'diagnostics'}, reply
    assert all(isinstance(value, str) for value in reply.values()), reply
assert replies[0]['result'] == ''
assert replies[1]['result'] == '42'
assert replies[2]['result'] == '43'
assert 'café 🌍' in replies[3]['result']
assert replies[4]['result'] == '44' and 'hello' in replies[4]['stdout'], replies[4]
assert replies[5]['diagnostics'] and replies[6]['result'] == '45'
for index in [7, 8, 9]:
    assert replies[index]['diagnostics'], replies[index]
assert replies[10] == {'result': '', 'stdout': '', 'diagnostics': ''}
assert replies[11]['result'] == '"' + 'a' * 300_000 + '"'
assert replies[12]['result'] == '40'
assert 'cell failure' in replies[13]['diagnostics'], replies[13]
assert replies[14]['result'] == '46'
assert '\x1b' not in run.stdout
print(f'{len(replies)} formatter protocol cases passed')
