"""Check queued execution cancellation and explicit continue-on-error behavior."""

import argparse
import tempfile
from pathlib import Path

from jupyter_client import KernelManager
from jupyter_client.kernelspec import KernelSpecManager

from iroc.__main__ import install

parser = argparse.ArgumentParser()
parser.add_argument("--roc", required=True)
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix="iroc-run-all-") as directory:
    install(["--prefix", directory, "--roc", args.roc])
    manager = KernelManager(
        kernel_name="roc",
        kernel_spec_manager=KernelSpecManager(
            kernel_dirs=[str(Path(directory, "share/jupyter/kernels"))]
        ),
    )
    manager.start_kernel()
    client = manager.blocking_client()
    client.start_channels()
    try:
        client.wait_for_ready(timeout=30)

        def batch(codes, stop_on_error=True):
            ids = [client.execute(code, stop_on_error=stop_on_error) for code in codes]
            replies = {}
            while len(replies) < len(ids):
                msg = client.get_shell_msg(timeout=30)
                parent = msg["parent_header"].get("msg_id")
                if parent in ids:
                    replies[parent] = msg["content"]
            idle = set()
            while len(idle) < len(ids):
                msg = client.get_iopub_msg(timeout=30)
                parent = msg["parent_header"].get("msg_id")
                if (
                    parent in ids
                    and msg["msg_type"] == "status"
                    and msg["content"]["execution_state"] == "idle"
                ):
                    idle.add(parent)
            return [replies[key] for key in ids]

        for error in [
            "missing_name",
            "1 + True",
            "Html(42.I64)",
            'Json("invalid json")',
        ]:
            replies = batch(["before = 40.I64", error, "after = 99.I64", "before + 2"])
            statuses = [reply["status"] for reply in replies]
            assert statuses == ["ok", "error", "aborted", "aborted"], (error, replies)
            replies = batch(["after"], stop_on_error=False)
            assert replies[0]["status"] == "error", replies
            replies = batch(["before + 2"])
            assert replies[0]["status"] == "ok", replies
        replies = batch(
            ["missing_name", "continued = 7.I64", "continued"], stop_on_error=False
        )
        assert [reply["status"] for reply in replies] == ["error", "ok", "ok"], replies
        print(
            "Run All cancellation, state preservation, recovery, and explicit continue-on-error passed"
        )
    finally:
        client.stop_channels()
        manager.shutdown_kernel()
