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
formatter = Path(__file__).resolve().parents[1] / 'iroc' / 'json-repl-formatter.roc'

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
    ('Json(Json.to_str({name: "Roc", count: 42.I64, items: [1.I64, 2.I64]}))',
     'application/json', {"name": "Roc", "count": 42, "items": [1, 2]}, 'json'),
    ('Html("")', 'text/html', '', 'text'),
    ('if True Html("chosen") else Other("skipped")', 'text/html', 'chosen', 'text'),
]
for payload in ['**Einstein** found that $E = mc^2$.', '$$E = mc^2$$', r'$$\frac{1}{2}$$']:
    rich_cases.append(('Markdown(' + json.dumps(payload) + ')', 'text/markdown', payload, 'text'))
rich_start = len(requests)
requests.extend({'code': code} for code, *_ in rich_cases)
plain_cases = ['LatexMath("x^2")', 'LatexMath(42.I64)', 'LatexMath', 'LatexMath("a", "b")', 'Latex("$$x^2$$")', 'Latex(42.I64)', '"Html(hello)"', '[Html("nested")]', '{value: Html("nested")}',
               'Other("<b>plain</b>")', '|number| number', '|number| number + 1', '42.I64', '42', 'True']
plain_start = len(requests)
requests.extend({'code': code} for code in plain_cases)
bad_start = len(requests)
requests.extend({'code': code} for code in ['Html(42.I64)', 'Markdown', 'Svg("a", "b")'])
state_start = len(requests)
requests.extend({'code': code} for code in ['page = Html("saved")', 'page',
    '{\n dbg "once"\n Html("once")\n}', 'roc_repl_value_0 = 7.I64', 'roc_repl_value_0'])
multiline_cases = [
    ('str =\n  \\\\first line\n  \\\\second line', ''),
    ('str', '"first line\nsecond line"'),
    ('another =\n  \\\\first\n  \\\\second\nanother', '"first\nsecond"'),
    ('\\\\first\n\\\\second', '"first\nsecond"'),
    ('spaces =\n  \\\\first  \n  \\\\second  ', ''),
    ('spaces', '"first  \nsecond  "'),
    ('\\\\first\n\\\\\n\\\\third', '"first\n\nthird"'),
    ('(\n  \\\\first\n  \\\\second\n)', '"first\nsecond"'),
    ('\\\\hello ${"world"}\n\\\\next', '"hello world\nnext"'),
]
multiline_start = len(requests)
requests.extend({'code': code} for code, _ in multiline_cases)
type_cases = [
    ('s = "Hello"\n:t s', 's : Str'),
    (':t s', 's : Str'),
    (':t\ts', 's : Str'),
    (':t s\ns', '"Hello"'),
    ('Html("old")\n:t s', 's : Str'),
    ('"literal :t s"', '"literal :t s"'),
    ('typed_lines =\n  \\\\first\n  \\\\second\n:t typed_lines', 'typed_lines : Str'),
    ('s', '"Hello"'),
]
type_start = len(requests)
requests.extend({"code": code} for code, _ in type_cases)
numeric_cases = [
    ('1+2+3', '6.0'),
    ('(1 + 2) * 3', '9.0'),
    ('[1 + 2, 3 + 4]', '[3.0, 7.0]'),
    ('1.I64 + 2 + 3', '6'),
    ('x + 2 + 3', '45'),
    ('add_one = |number| number + 1', ''),
    ('add_one(2.I64)', '3'),
    ('add_one(2)', '3.0'),
]
numeric_start = len(requests)
requests.extend({'code': code} for code, _ in numeric_cases)
requests.extend([{'code': '1 + True'}, {'code': '1 + 2 + 3'}])
wire = '\n'.join(x if isinstance(x, str) else json.dumps(x, ensure_ascii=False) for x in requests)
# Intentionally omit the last delimiter to exercise EOF framing.
run = subprocess.run([args.roc, 'repl', '--specialize=' + args.specialize, '--formatter', str(formatter)], input=wire,
                     text=True, capture_output=True, timeout=180)
assert run.returncode == 0, (f"Failed after {len(run.stdout.splitlines())} replies", run.stderr)
replies = [json.loads(line) for line in run.stdout.splitlines()]
assert len(replies) == len(requests), (len(replies), run.stderr)
for reply in replies:
    assert set(reply) == {'status', 'result', 'stdout', 'diagnostics', 'data'}, reply
    assert all(isinstance(reply[key], str) for key in ['result', 'stdout', 'diagnostics']), reply
    assert isinstance(reply['data'], list), reply
    assert reply['status'] in ('success', 'failure', 'incomplete'), reply
assert replies[0]['result'] == ''
assert replies[1]['result'] == '42'
assert replies[2]['result'] == '43'
assert 'café 🌍' in replies[3]['result']
assert replies[4]['result'] == '44' and 'hello' in replies[4]['stdout'], replies[4]
assert replies[5]['status'] == 'failure' and replies[6]['status'] == 'success'
assert replies[6]['result'] == '45'
for index in [7, 8, 9]:
    assert replies[index]['status'] == 'failure', replies[index]
assert replies[10] == {'status': 'success', 'result': '', 'stdout': '', 'diagnostics': '', 'data': []}
assert replies[11]['result'] == '"' + 'a' * args.large_string_size + '"'
assert replies[12]['result'] == '40'
assert replies[13]['status'] == 'failure' and 'cell failure' in replies[13]['diagnostics'], replies[13]
assert replies[14]['result'] == '46'
for reply, (_, mime, payload, encoding) in zip(replies[rich_start:], rich_cases):
    assert reply['status'] == 'success', reply
    assert len(reply['data']) == 1, reply
    entry = reply['data'][0]
    assert entry['mime'] == mime and entry['encoding'] == encoding, reply
    assert (json.loads(entry['value']) if encoding == 'json' else entry['value']) == payload, reply
for reply in replies[plain_start:bad_start]:
    assert reply['status'] == 'success' and reply['data'] == [], reply
for reply in replies[bad_start:state_start]:
    assert reply['status'] == 'failure'
    assert 'expects exactly one Str payload' in reply['diagnostics'], reply
assert replies[state_start]['result'] == ''
assert replies[state_start + 1]['data'][0]['value'] == 'saved'
assert replies[state_start + 2]['stdout'].count('once') == 1, replies[state_start + 2]
assert replies[state_start + 2]['data'][0]['value'] == 'once'
assert replies[state_start + 4]['result'] == '7', replies[state_start + 4]
for reply, (_, expected) in zip(replies[multiline_start:], multiline_cases):
    assert reply["status"] == "success" and reply["result"] == expected, reply
for reply, (_, expected) in zip(replies[type_start:], type_cases):
    assert reply["status"] == "success" and reply["result"] == expected and reply["data"] == [], reply
for reply, (_, expected) in zip(replies[numeric_start:], numeric_cases):
    assert reply['status'] == 'success' and reply['result'] == expected and reply['data'] == [], reply
assert replies[-2]['status'] == 'failure', replies[-2]
assert replies[-1]['status'] == 'success' and replies[-1]['result'] == '6.0', replies[-1]
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
    assert nominal[index]['status'] == 'success' and nominal[index]['data'] == [], nominal[index]
assert nominal[3]['result'] == 'Html(fake)', nominal[3]
assert nominal[4]['status'] == 'failure'
assert 'expects exactly one Str payload' in nominal[4]['diagnostics'], nominal[4]
assert nominal[5]['data'][0]['value'] == 'real', nominal[5]
assert '\x1b' not in run.stdout
print(f'{len(replies) + len(nominal)} formatter protocol cases passed')

# A failed or incomplete cell retains earlier commits and its last successful result.
status_cases = [
    ('partial = 7.I64\nHtml("prior")\nmissing_status\nskipped = 9.I64', 'failure', 'Html("prior")'),
    ('partial', 'success', '7'),
    ('partial = 1 + True', 'failure', ''),
    ('partial', 'success', '7'),
    ('skipped', 'failure', ''),
    ('kept = 8.I64\n2.I64\n[1,', 'incomplete', '2'),
    ('kept', 'success', '8'),
    (']', 'failure', ''),  # incomplete source is not buffered across requests
    ('3.I64\nexpect 1 == 2\n44.I64', 'failure', '3'),
    ('4.I64\ncrash "failure"\n55.I64', 'failure', '4'),
    (':t missing\n66.I64', 'failure', ''),
    ('1.I64\nlast = 2.I64', 'success', '1'),
    ('1.I64\nexpect 1 == 1', 'success', '1'),
    ('1.I64\ndbg "hello"', 'success', '{}'),
    ('1.I64\nfor n in [1, 2] { dbg n }', 'success', '1'),
    ('partial + kept', 'success', '15'),
]
status_run = subprocess.run(
    [args.roc, 'repl', '--specialize=' + args.specialize, '--formatter', str(formatter)],
    input='\n'.join(json.dumps({'code': code}) for code, _, _ in status_cases),
    text=True, capture_output=True, timeout=90,
)
assert status_run.returncode == 0, status_run.stderr
status_replies = [json.loads(line) for line in status_run.stdout.splitlines()]
assert len(status_replies) == len(status_cases)
for reply, (_, status, result) in zip(status_replies, status_cases):
    assert reply['status'] == status and reply['result'] == result, reply
    if status != 'success':
        assert reply['data'] == [], reply
assert status_replies[-3]['stdout'] == '"hello"\n', status_replies[-3]
assert status_replies[-2]['stdout'] == '1.0\n2.0\n', status_replies[-2]
print(f'{len(status_cases)} execution-status cases passed')
