"""Run iRoc, or register it with Jupyter using this Python environment."""

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path


def install(argv):
    from jupyter_client.kernelspec import KernelSpecManager

    parser = argparse.ArgumentParser(description="Install the Roc Jupyter kernel")
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument(
        "--user", action="store_true", help="Install for this user (default)"
    )
    scope.add_argument(
        "--sys-prefix", action="store_true", help="Install in this Python environment"
    )
    scope.add_argument("--prefix", help="Install under a custom prefix")
    parser.add_argument("--roc", help="Roc executable; otherwise use IROC_ROC or PATH")
    args = parser.parse_args(argv)
    spec = {
        "argv": [sys.executable, "-m", "iroc", "-f", "{connection_file}"],
        "display_name": "Roc",
        "language": "roc",
        "interrupt_mode": "signal",
    }
    if args.roc:
        spec["env"] = {"IROC_ROC": os.path.abspath(os.path.expanduser(args.roc))}
    prefix = sys.prefix if args.sys_prefix else args.prefix
    with tempfile.TemporaryDirectory(prefix="iroc-install-") as directory:
        Path(directory, "kernel.json").write_text(
            json.dumps(spec, indent=2), encoding="utf-8"
        )
        destination = KernelSpecManager().install_kernel_spec(
            directory,
            kernel_name="roc",
            user=prefix is None,
            prefix=prefix,
        )
    print(f"Installed Roc kernel in {destination}")


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("install", "--install"):
        install(sys.argv[2:])
    else:
        from ipykernel.kernelapp import IPKernelApp

        from .kernel import RocKernel

        app = IPKernelApp.instance(kernel_class=RocKernel)
        # CLI configuration takes precedence over IPython profile files, which
        # may select the host's Python kernel (for example google.colab).
        app.initialize([*sys.argv[1:], "--IPKernelApp.kernel_class=iroc.kernel.RocKernel"])
        try:
            app.start()
        finally:
            app.close()


if __name__ == "__main__":
    main()
