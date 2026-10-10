"""Jupyter protocol adapter; Roc remains responsible for evaluating code."""

import atexit

import simplejson
from ipykernel.kernelbase import Kernel
from jupyter_client.jsonutil import json_default

from . import __version__
from .repl import ReplError, RocRepl


def pack_message(value):
    # Preserve JSON decimal values without first rounding through binary floats.
    return simplejson.dumps(
        value,
        use_decimal=True,
        ensure_ascii=False,
        allow_nan=False,
        default=json_default,
    ).encode("utf-8")


class RocKernel(Kernel):
    implementation = "iroc"
    implementation_version = __version__
    language = "roc"
    language_version = ""
    language_info = {"name": "roc", "mimetype": "text/x-roc", "file_extension": ".roc"}
    banner = "Roc Jupyter kernel"

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.session.pack = pack_message
        self.repl = RocRepl()
        atexit.register(self.repl.close)

    def error_reply(self, name, message, silent):
        content = {"ename": name, "evalue": message, "traceback": [message]}
        if not silent:
            self.send_response(self.iopub_socket, "error", content)
        return {"status": "error", "execution_count": self.execution_count, **content}

    async def do_execute(
        self,
        code,
        silent,
        store_history=True,
        user_expressions=None,
        allow_stdin=False,
        *,
        cell_meta=None,
        cell_id=None,
    ):
        try:
            response = self.repl.execute(code)
        except KeyboardInterrupt:
            self.repl.close()
            return self.error_reply(
                "KeyboardInterrupt",
                "Execution interrupted. Roc state was cleared; rerun your definitions.",
                silent,
            )
        except ReplError as error:
            return self.error_reply("RocProcessError", str(error), silent)
        if response["stdout"] and not silent:
            self.send_response(
                self.iopub_socket,
                "stream",
                {"name": "stdout", "text": response["stdout"]},
            )
        if response["diagnostics"]:
            return self.error_reply("RocError", response["diagnostics"], silent)
        if response["bundle"] and not silent:
            self.send_response(
                self.iopub_socket,
                "execute_result",
                {
                    "execution_count": self.execution_count,
                    "data": response["bundle"],
                    "metadata": {},
                },
            )
        expressions = {
            key: {
                "status": "error",
                "ename": "NotImplementedError",
                "evalue": "Roc user_expressions are not supported",
                "traceback": [],
            }
            for key in (user_expressions or {})
        }
        return {
            "status": "ok",
            "execution_count": self.execution_count,
            "payload": [],
            "user_expressions": expressions,
        }

    def do_is_complete(self, code):
        # Completeness requires Roc's parser; do not approximate its grammar here.
        return {"status": "unknown"}

    async def do_shutdown(self, restart):
        self.repl.close()
        return {"status": "ok", "restart": restart}
