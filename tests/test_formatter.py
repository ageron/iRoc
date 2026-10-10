"""Exercise the actual Roc formatter process; no third-party packages required."""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--roc', default='roc')
parser.add_argument('--specialize', choices=['yes', 'no'], default='yes')
parser.add_argument('--large-string-size', type=int, default=300_000, help='Use a smaller multi-buffer value for debug compiler runs')
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
    {'code': '"' + 'a' * args.large_string_size + '"'},
    {'code': 'x'},
    {'code': 'crash "cell failure"'},
    {'code': 'x + 6'},
]
rich_cases = [
    ('Html("<b>café 🌍</b>")', 'text/html', '<b>café 🌍</b>', 'text'),
    ('Markdown("**bold**")', 'text/markdown', '**bold**', 'text'),
    ('Svg("<svg></svg>")', 'image/svg+xml', '<svg></svg>', 'text'),
    ('Latex("$$x^2$$")', 'text/latex', '$$x^2$$', 'text'),
    ('StructuredJson(Json.to_str({name: "Roc", count: 42.I64, items: [1.I64, 2.I64]}))',
     'application/json', {"name": "Roc", "count": 42, "items": [1, 2]}, 'json'),
    ('Html("")', 'text/html', '', 'text'),
    ('if True Html("chosen") else Other("skipped")', 'text/html', 'chosen', 'text'),
]
rich_start = len(requests)
requests.extend({'code': code} for code, *_ in rich_cases)
plain_cases = ['"Html(hello)"', '[Html("nested")]', '{value: Html("nested")}',
               'Other("<b>plain</b>")', '|number| number', '|number| number + 1', '42.I64', '42', 'True']
plain_start = len(requests)
requests.extend({'code': code} for code in plain_cases)
bad_start = len(requests)
requests.extend({'code': code} for code in ['Html(42.I64)', 'Markdown', 'Svg("a", "b")'])
state_start = len(requests)
requests.extend({'code': code} for code in ['page = Html("saved")', 'page',
    '{\n dbg "once"\n Html("once")\n}', 'roc_repl_value_0 = 7.I64', 'roc_repl_value_0'])
wire = '\n'.join(x if isinstance(x, str) else json.dumps(x, ensure_ascii=False) for x in requests)
# Intentionally omit the last delimiter to exercise EOF framing.
run = subprocess.run([args.roc, 'repl', '--specialize=' + args.specialize, '--formatter', str(formatter)], input=wire,
                     text=True, capture_output=True, timeout=180)
assert run.returncode == 0, (f"Failed after {len(run.stdout.splitlines())} replies", run.stderr)
replies = [json.loads(line) for line in run.stdout.splitlines()]
assert len(replies) == len(requests), (len(replies), run.stderr)
for reply in replies:
    assert set(reply) == {'result', 'stdout', 'diagnostics', 'data'}, reply
    assert all(isinstance(reply[key], str) for key in ['result', 'stdout', 'diagnostics']), reply
    assert isinstance(reply['data'], list), reply
assert replies[0]['result'] == ''
assert replies[1]['result'] == '42'
assert replies[2]['result'] == '43'
assert 'café 🌍' in replies[3]['result']
assert replies[4]['result'] == '44' and 'hello' in replies[4]['stdout'], replies[4]
assert replies[5]['diagnostics'] and replies[6]['result'] == '45'
for index in [7, 8, 9]:
    assert replies[index]['diagnostics'], replies[index]
assert replies[10] == {'result': '', 'stdout': '', 'diagnostics': '', 'data': []}
assert replies[11]['result'] == '"' + 'a' * args.large_string_size + '"'
assert replies[12]['result'] == '40'
assert 'cell failure' in replies[13]['diagnostics'], replies[13]
assert replies[14]['result'] == '46'
for reply, (_, mime, payload, encoding) in zip(replies[rich_start:], rich_cases):
    assert not reply['diagnostics'], reply
    assert len(reply['data']) == 1, reply
    entry = reply['data'][0]
    assert entry['mime'] == mime and entry['encoding'] == encoding, reply
    assert (json.loads(entry['value']) if encoding == 'json' else entry['value']) == payload, reply
for reply in replies[plain_start:bad_start]:
    assert not reply['diagnostics'] and reply['data'] == [], reply
for reply in replies[bad_start:state_start]:
    assert 'expects exactly one Str payload' in reply['diagnostics'], reply
assert replies[state_start]['result'] == ''
assert replies[state_start + 1]['data'][0]['value'] == 'saved'
assert replies[state_start + 2]['stdout'].count('once') == 1, replies[state_start + 2]
assert replies[state_start + 2]['data'][0]['value'] == 'once'
assert replies[state_start + 4]['result'] == '7', replies[state_start + 4]
# Nominal types and their custom inspection text cannot impersonate display tags.
nominal_requests = [
    'Wrapped := [Html(Str)]',
    'Wrapped.(Html("wrapped"))',
    'Forged := Str.{ to_inspect = |_| "Html(fake)" }',
    'Forged.("secret")',
    'Html(Forged.("secret"))',
    'Html("real")',
]
nominal_run = subprocess.run([args.roc, 'repl', '--specialize=' + args.specialize, '--formatter', str(formatter)],
    input='\n'.join(json.dumps({'code': code}) for code in nominal_requests),
    text=True, capture_output=True, timeout=90)
assert nominal_run.returncode == 0, nominal_run.stderr
nominal = [json.loads(line) for line in nominal_run.stdout.splitlines()]
assert len(nominal) == len(nominal_requests), nominal
for index in [0, 1, 2, 3]:
    assert not nominal[index]['diagnostics'] and nominal[index]['data'] == [], nominal[index]
assert nominal[3]['result'] == 'Html(fake)', nominal[3]
assert 'expects exactly one Str payload' in nominal[4]['diagnostics'], nominal[4]
assert nominal[5]['data'][0]['value'] == 'real', nominal[5]
assert '\x1b' not in run.stdout
print(f'{len(replies) + len(nominal)} formatter protocol cases passed')
