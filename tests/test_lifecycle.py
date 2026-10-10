"""Exercise interruption, restart, silent execution, and shutdown via Jupyter."""

import argparse
import tempfile
import time
from pathlib import Path

import psutil
from jupyter_client import KernelManager
from jupyter_client.kernelspec import KernelSpecManager

from iroc.__main__ import install

parser = argparse.ArgumentParser()
parser.add_argument("--roc", required=True)
args = parser.parse_args()

with tempfile.TemporaryDirectory(prefix="iroc-lifecycle-") as directory:
    install(["--prefix", directory, "--roc", args.roc])
    specs = KernelSpecManager(
        kernel_dirs=[str(Path(directory, "share/jupyter/kernels"))]
    )
    manager = KernelManager(kernel_name="roc", kernel_spec_manager=specs)
    manager.start_kernel()
    client = manager.blocking_client()
    client.start_channels()

    def result(message_id):
        while True:
            reply = client.get_shell_msg(timeout=30)
            if reply["parent_header"].get("msg_id") == message_id:
                break
        messages = []
        while True:
            message = client.get_iopub_msg(timeout=30)
            if message["parent_header"].get("msg_id") != message_id:
                continue
            messages.append(message)
            if (
                message["msg_type"] == "status"
                and message["content"]["execution_state"] == "idle"
            ):
                return reply["content"], messages

    try:
        client.wait_for_ready(timeout=30)
        reply, _ = result(client.execute("x = 42.I64"))
        assert reply["status"] == "ok", reply
        reply, messages = result(client.execute('{ dbg "hidden"\nx + 1 }', silent=True))
        assert reply["status"] == "ok", reply
        assert not any(
            m["msg_type"] in ["stream", "execute_result", "error", "execute_input"]
            for m in messages
        ), messages
        request = client.execute("while True {}")
        while True:
            message = client.get_iopub_msg(timeout=30)
            if (
                message["parent_header"].get("msg_id") == request
                and message["msg_type"] == "execute_input"
            ):
                break
        time.sleep(0.5)
        manager.interrupt_kernel()
        reply, _ = result(request)
        assert reply["status"] == "error" and reply["ename"] == "KeyboardInterrupt", (
            reply
        )
        assert "state was cleared" in reply["evalue"], reply
        reply, _ = result(client.execute("x", stop_on_error=False))
        assert reply["status"] == "error", reply
        reply, _ = result(client.execute("1 + 2 + 3"))
        assert reply["status"] == "ok", reply
        result(client.execute("saved = 17"))
        manager.restart_kernel(now=False)
        client.wait_for_ready(timeout=30)
        reply, _ = result(client.execute("saved", stop_on_error=False))
        assert reply["status"] == "error", reply
        reply, _ = result(client.execute("2 + 3"))
        assert reply["status"] == "ok", reply
        children = psutil.Process(manager.provisioner.pid).children()
        roc_children = [
            child for child in children if child.name() == Path(args.roc).name
        ]
        assert len(roc_children) == 1, children
        roc_children[0].kill()
        time.sleep(0.1)
        reply, _ = result(client.execute("42", stop_on_error=False))
        assert (
            reply["ename"] == "RocProcessError"
            and "state was cleared" in reply["evalue"]
        ), reply
        reply, _ = result(client.execute("42"))
        assert reply["status"] == "ok", reply
        request = client.execute("while True {}")
        while True:
            message = client.get_iopub_msg(timeout=30)
            if (
                message["parent_header"].get("msg_id") == request
                and message["msg_type"] == "execute_input"
            ):
                break
        time.sleep(0.5)
        shutdown = client.shutdown()
        reply = client.get_control_msg(timeout=10)
        assert reply["parent_header"]["msg_id"] == shutdown, reply
        manager.provisioner.process.wait(timeout=10)
        assert manager.provisioner.process.returncode == 0
        print(
            "Jupyter silent execution, interruption, process failure, restart, and busy shutdown passed"
        )
    finally:
        client.stop_channels()
        manager.shutdown_kernel(now=False)
        assert not manager.is_alive()
