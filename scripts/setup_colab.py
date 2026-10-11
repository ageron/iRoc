"""Install iRoc in an isolated Colab environment, then check kernel startup.

Run with Colab's Python before switching the notebook to the Roc kernel.
Uses only the standard library; iRoc dependencies go in /content/iroc-env.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
from textwrap import dedent
from urllib.request import urlretrieve
from zipfile import ZipFile

COMPILER_URL = (
    "https://github.com/ageron/roc/releases/download/roc-iroc-2026-10-11/"
    "roc-iroc-linux-x86_64.zip"
)

ARCHIVE = "/content/roc-iroc-linux-x86_64.zip"
ROC = "/content/roc-iroc-linux-x86_64"
ENV = "/content/iroc-env"
PYTHON = f"{ENV}/bin/python"
VIRTUALENV = "/content/virtualenv.pyz"


def run(*args):
    # Forward subprocess output through Python so Colab displays it reliably.
    with subprocess.Popen(
        args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, bufsize=1,
    ) as process:
        tail = []
        for line in process.stdout:
            print(line, end="", flush=True)
            tail.append(line)
            tail = tail[-80:]
        status = process.wait()
    if status:
        raise RuntimeError(
            f"Command failed (exit {status}): {args[:3]}\n" + "".join(tail)
        )


def main():
    print("Downloading Roc…", flush=True)
    urlretrieve(COMPILER_URL, ARCHIVE)
    with ZipFile(ARCHIVE) as archive:
        # Extract only the named executable, never arbitrary archive paths.
        with archive.open(Path(ROC).name) as executable, open(ROC, "wb") as output:
            shutil.copyfileobj(executable, output)

    os.chmod(ROC, os.stat(ROC).st_mode | 0o111)
    run(ROC, "version")

    # Keep iRoc's dependencies separate from Colab's Python environment.
    # PyPA's standalone virtualenv includes its bootstrap dependencies.
    # It works without system venv/ensurepip and does not modify Colab's packages.
    version = f"{sys.version_info.major}.{sys.version_info.minor}"
    urlretrieve(f"https://bootstrap.pypa.io/virtualenv/{version}/virtualenv.pyz", VIRTUALENV)
    run(sys.executable, VIRTUALENV, "--python", sys.executable, ENV)
    run(PYTHON, "-m", "pip", "install", "--upgrade",
        "git+https://github.com/ageron/iRoc.git@main")

    # Check the bundled formatter and compiler together before switching kernels.
    run(PYTHON, "-c", dedent("""
    from pathlib import Path
    import sys
    import iroc
    from iroc.repl import RocRepl

    formatter = Path(iroc.__file__).with_name("json-repl-formatter.roc")
    if not formatter.is_file():
        raise FileNotFoundError(f"Missing formatter: {formatter}")
    print(f"Formatter found: {formatter}")
    repl = RocRepl(roc=sys.argv[1])
    try:
        reply = repl.execute("1 + 2 + 3")
        if reply["diagnostics"]:
            raise RuntimeError(reply["diagnostics"])
        print("Roc test result:", reply["result"])
    finally:
        repl.close()
    """), ROC)

    # Register where Colab's Jupyter server can discover the kernel.
    run(PYTHON, "-m", "iroc", "install", "--user", "--roc", ROC)
    # Verify the registered kernel can start, independently of Colab's selection.
    run(PYTHON, "-c", dedent("""
    from jupyter_client import KernelManager

    manager = KernelManager(kernel_name="roc")
    print("Kernel command:", manager.kernel_spec.argv, flush=True)
    manager.start_kernel()
    client = manager.blocking_client()
    client.start_channels()
    try:
        client.wait_for_ready(timeout=60)
        message_id = client.kernel_info()
        while True:
            reply = client.get_shell_msg(timeout=30)
            if reply.get("parent_header", {}).get("msg_id") == message_id:
                break
        info = reply["content"]
        if info["implementation"] != "iroc":
            raise RuntimeError(f"Unexpected kernel: {info}")
        print("Registered iRoc kernel starts successfully.")
    finally:
        client.stop_channels()
        manager.shutdown_kernel(now=True)
    """))
    print("Setup complete. Refresh this page, then run the Roc cells below.")


if __name__ == "__main__":
    main()
