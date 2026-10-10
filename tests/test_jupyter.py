"""Real Jupyter wire-protocol smoke test (requires jupyter-client and pyzmq)."""
import argparse
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile

from jupyter_client import BlockingKernelClient
from jupyter_client.connect import write_connection_file

parser = argparse.ArgumentParser()
parser.add_argument('--roc', required=True)
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='iroc-jupyter-') as directory:
    connection, _ = write_connection_file(str(Path(directory) / 'connection.json'))
    environment = dict(os.environ, IROC_ROC=str(Path(args.roc).resolve()))
    with open(Path(directory) / 'kernel.log', 'w+') as log:
        process = subprocess.Popen([sys.executable, "-m", "iroc", "-f", connection], env=environment, stdout=log, stderr=log, start_new_session=True)
        client = BlockingKernelClient(connection_file=connection)
        client.load_connection_file()
        client.start_channels()
        try:
            client.wait_for_ready(timeout=90)
            cases = [
                ('1+2+3', {'text/plain': '6.0'}, None),
                ('1.I64 + 2 + 3', {'text/plain': '6'}, None),
                ('x = 40.I64', None, None),
                ('x + 2', {'text/plain': '42'}, None),
                ('missing_name', None, 'missing_name'),
                ('x + 3', {'text/plain': '43'}, None),
                ('s = "Hello"\n:t s', {'text/plain': 's : Str'}, None),
                (':t s', {'text/plain': 's : Str'}, None),
                ('Html("old")\n:t s', {'text/plain': 's : Str'}, None),
                (':t s\ns', {'text/plain': '"Hello"'}, None),
            ]
            for tag, mime, payload in [
                ('Html', 'text/html', '<b title="hi">café 🌍</b>\n<p>next</p>'),
                ('Markdown', 'text/markdown', '# Title\n**bold**'),
                ('Markdown', 'text/markdown', '**Einstein** found that $E = mc^2$.'),
                ('Markdown', 'text/markdown', '$$E = mc^2$$'),
                ('Markdown', 'text/markdown', r'$$\frac{1}{2}$$'),
                ('Svg', 'image/svg+xml', '<svg xmlns="http://www.w3.org/2000/svg"><circle r="5"/></svg>'),
            ]:
                code = f'{tag}({json.dumps(payload, ensure_ascii=False)})'
                cases.append((code, {mime: payload}, None))
            json_value = {'nested': [True, None, {'name': 'Roc', 'large': 123456789012345678901234567890}]}
            cases.extend([
                ('LatexMath("f(x) = x^2")', {'text/plain': 'LatexMath("f(x) = x^2")'}, None),
                ('Latex("f(x) = x^2")', {'text/plain': 'Latex("f(x) = x^2")'}, None),
                ('LatexMath(42.I64)', {'text/plain': 'LatexMath(42)'}, None),
                ('str =\n  \\\\first line\n  \\\\second line', None, None),
                ('str', {'text/plain': '"first line\nsecond line"'}, None),
                ('StructuredJson(' + json.dumps(json.dumps(json_value)) + ')', {'application/json': json_value}, None),
                ('StructuredJson(Json.to_str([1.I64, 2.I64]))', {'application/json': [1, 2]}, None),
                ('Html("")', {'text/html': ''}, None),
                ('"Html(hello)"', {'text/plain': '"Html(hello)"'}, None),
                ('Html(42.I64)', None, 'expects exactly one Str payload'),
                ('StructuredJson("invalid json")', None, 'valid JSON'),
                ('x + 4', {'text/plain': '44'}, None),
                (json.dumps('a' * 300_000), {'text/plain': json.dumps('a' * 300_000)}, None),
            ])
            for code, expected, failure in cases:
                message_id = client.execute(code)
                reply = client.get_shell_msg(timeout=90)
                while reply['parent_header'].get('msg_id') != message_id:
                    reply = client.get_shell_msg(timeout=90)
                assert reply['content']['status'] == ('error' if failure else 'ok'), reply
                messages = []
                while True:
                    message = client.get_iopub_msg(timeout=90)
                    if message['parent_header'].get('msg_id') != message_id:
                        continue
                    messages.append(message)
                    if message['msg_type'] == 'status' and message['content']['execution_state'] == 'idle':
                        break
                if expected is not None:
                    results = [m['content']['data'] for m in messages if m['msg_type'] == 'execute_result']
                    assert len(results) == 1, messages
                    assert isinstance(results[0]['text/plain'], str), results
                    assert all(results[0].get(mime) == value for mime, value in expected.items()), results
                    if set(expected) == {'text/plain'}:
                        assert set(results[0]) == {'text/plain'}, results
                if failure:
                    assert any(m['msg_type'] == 'error' and failure in m['content']['evalue'] for m in messages), messages
            print(f'{len(cases)} live Jupyter cell executions passed')
        except BaseException:
            log.seek(0)
            print(log.read())
            raise
        finally:
            shutdown_id = client.shutdown()
            shutdown_reply = client.get_control_msg(timeout=10)
            assert shutdown_reply["parent_header"]["msg_id"] == shutdown_id, shutdown_reply
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                log.seek(0)
                print(log.read())
                process.kill()
                process.wait(timeout=10)
                raise
            finally:
                client.stop_channels()
            assert process.returncode == 0, process.returncode
