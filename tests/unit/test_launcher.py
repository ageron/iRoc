"""The iRoc launcher must not inherit a host's Python kernel class."""

import json
import os
import sys

from jupyter_client import KernelManager
from jupyter_client.kernelspec import KernelSpecManager


def test_host_profile_cannot_override_roc_kernel(tmp_path):
    profile = tmp_path / "ipython" / "profile_default"
    profile.mkdir(parents=True)
    (profile / "ipython_kernel_config.py").write_text(
        'c.IPKernelApp.kernel_class = "google.colab._kernel.Kernel"\n'
    )
    kernels = tmp_path / "kernels"
    spec = kernels / "roc"
    spec.mkdir(parents=True)
    (spec / "kernel.json").write_text(json.dumps({
        "argv": [sys.executable, "-m", "iroc", "-f", "{connection_file}"],
        "display_name": "Roc",
        "language": "roc",
    }))
    manager = KernelManager(
        kernel_name="roc",
        kernel_spec_manager=KernelSpecManager(kernel_dirs=[str(kernels)]),
    )
    manager.start_kernel(env={**os.environ, "IPYTHONDIR": str(profile.parent)})
    client = manager.blocking_client()
    client.start_channels()
    try:
        client.wait_for_ready(timeout=20)
        request = client.kernel_info()
        reply = client.get_shell_msg(timeout=10)
        assert reply["parent_header"]["msg_id"] == request
        assert reply["content"]["implementation"] == "iroc"
        assert reply["content"]["language_info"]["name"] == "roc"
    finally:
        client.stop_channels()
        manager.shutdown_kernel(now=True)
