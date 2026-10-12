"""One persistent Roc process per notebook kernel, speaking formatter JSON."""

import json
import os
import signal
import subprocess
import tempfile
import threading
from decimal import Decimal
from pathlib import Path


class ReplError(Exception):
    """The formatter transport failed; the current Roc scope has been discarded."""


def reject_constant(value):
    raise ValueError(f"Invalid JSON constant: {value}")


def decode_response(line):
    response = json.loads(line, parse_constant=reject_constant)
    if (
        not isinstance(response, dict)
        or any(
            not isinstance(response.get(key), str)
            for key in ("result", "stdout", "diagnostics")
        )
        or response.get("status") not in ("success", "incomplete", "failure")
        or not isinstance(response.get("data"), list)
    ):
        raise ValueError("Invalid formatter response")
    bundle = {"text/plain": response["result"]} if response["result"] else {}
    if response["status"] == "success":
        for entry in response["data"]:
            if not isinstance(entry, dict) or any(
                not isinstance(entry.get(key), str)
                for key in ("mime", "encoding", "value")
            ):
                raise ValueError("Invalid formatter MIME entry")
            if entry["encoding"] == "text":
                value = entry["value"]
            elif entry["encoding"] == "json":
                try:
                    value = json.loads(
                        entry["value"],
                        parse_float=Decimal,
                        parse_constant=reject_constant,
                    )
                except ValueError:
                    response["status"] = "failure"
                    problem = "Json expects a valid JSON string (use Json.to_str(value))"
                    response["diagnostics"] = "\n".join(
                        text for text in (response["diagnostics"], problem) if text
                    )
                    break
            else:
                raise ValueError("Formatter returned an invalid MIME encoding")
            bundle[entry["mime"]] = value
    response["bundle"] = bundle
    return response


class RocRepl:
    def __init__(self, roc=None, formatter=None):
        self.roc = roc or os.environ.get("IROC_ROC", "roc")
        self.formatter = str(
            formatter or Path(__file__).with_name("json-repl-formatter.roc")
        )
        self.process = None
        self.stderr = None
        self._lock = threading.RLock()

    def start(self):
        # A file avoids a full stderr pipe blocking the compiler while we read stdout.
        self.stderr = tempfile.TemporaryFile()
        try:
            self.process = subprocess.Popen(
                [self.roc, "repl", "--formatter", self.formatter],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=self.stderr,
                text=True,
                encoding="utf-8",
                start_new_session=True,
            )
        except OSError as error:
            self.close()
            raise ReplError(f"Could not start Roc ({self.roc}): {error}") from error

    def execute(self, code):
        with self._lock:
            if self.process is None:
                self.start()
            process = self.process
        try:
            process.stdin.write(json.dumps({"code": code}, ensure_ascii=False) + "\n")
            process.stdin.flush()
            line = process.stdout.readline()
            if not line or not line.endswith("\n"):
                raise ValueError("Roc exited without a complete formatter response")
            return decode_response(line)
        except (OSError, ValueError) as error:
            # Shutdown runs on Jupyter's control thread. Serialize teardown so
            # an in-flight execute can observe an already-closed session safely.
            with self._lock:
                self._stop()
                details = ""
                if self.stderr is not None:
                    self.stderr.seek(0, os.SEEK_END)
                    self.stderr.seek(max(0, self.stderr.tell() - 65536))
                    details = (
                        self.stderr.read().decode("utf-8", errors="replace").strip()
                    )
                self.close()
            message = f"{error}. Roc state was cleared; rerun your definitions."
            raise ReplError(f"{message}\n{details}" if details else message) from error

    def _stop(self):
        process, self.process = self.process, None
        if process is None:
            return
        if process.poll() is None:
            # Termination also works while a cell is executing; closing buffered
            # stdin first could block if a write was interrupted.
            try:
                if os.name == "posix":
                    os.killpg(process.pid, signal.SIGTERM)
                else:
                    process.terminate()
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                if os.name == "posix":
                    os.killpg(process.pid, signal.SIGKILL)
                else:
                    process.kill()
                process.wait()
        else:
            process.wait()
        for stream in (process.stdin, process.stdout):
            try:
                stream.close()
            except OSError:
                pass

    def close(self):
        with self._lock:
            self._stop()
            if self.stderr is not None:
                self.stderr.close()
                self.stderr = None
