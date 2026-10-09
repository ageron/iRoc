"""Real Jupyter wire-protocol smoke test (requires jupyter-client and pyzmq)."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import tempfile

from jupyter_client import BlockingKernelClient
from jupyter_client.connect import write_connection_file

parser = argparse.ArgumentParser()
parser.add_argument('--roc', required=True)
parser.add_argument('--kernel', default=str(Path(__file__).resolve().parents[1] / 'zig-out/bin/iroc'))
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='iroc-jupyter-') as directory:
    connection, _ = write_connection_file(str(Path(directory) / 'connection.json'))
    environment = dict(os.environ, PATH=str(Path(args.roc).resolve().parent) + os.pathsep + os.environ['PATH'])
    with open(Path(directory) / 'kernel.log', 'w+') as log:
        process = subprocess.Popen([args.kernel, connection], env=environment, stdout=log, stderr=log, start_new_session=True)
        client = BlockingKernelClient(connection_file=connection)
        client.load_connection_file()
        client.start_channels()
        try:
            client.wait_for_ready(timeout=90)
            for code, expected, failure in [('x = 40.I64', None, False), ('x + 2', '42', False),
                                            ('missing_name', None, True), ('x + 3', '43', False)]:
                message_id = client.execute(code)
                reply = client.get_shell_msg(timeout=90)
                assert reply['parent_header']['msg_id'] == message_id
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
                    assert any(m['msg_type'] == 'execute_result' and m['content']['data']['text/plain'] == expected for m in messages), messages
                if failure:
                    assert any(m['msg_type'] == 'error' and 'missing_name' in m['content']['evalue'] for m in messages), messages
            print('4 live Jupyter cell executions passed')
        except BaseException:
            log.seek(0)
            print(log.read())
            raise
        finally:
            client.stop_channels()
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=10)
