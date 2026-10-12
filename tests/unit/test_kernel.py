import asyncio
from functools import partial
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from iroc.kernel import RocKernel


@pytest.mark.parametrize("status", ["success", "incomplete", "failure"])
@pytest.mark.parametrize("diagnostics", ["", "a diagnostic"])
def test_execution_uses_status_not_diagnostic_text(status, diagnostics):
    response = {
        "status": status,
        "result": "42",
        "stdout": "debug output\n",
        "diagnostics": diagnostics,
        "bundle": {"text/plain": "42"},
    }
    kernel = SimpleNamespace(
        repl=SimpleNamespace(execute=Mock(return_value=response)),
        execution_count=1, iopub_socket=object(), send_response=Mock(),
    )
    kernel.error_reply = partial(RocKernel.error_reply, kernel)
    reply = asyncio.run(RocKernel.do_execute(kernel, "42", silent=False))
    assert reply["status"] == ("ok" if status == "success" else "error")
    messages = [(args[1], args[2]) for args, _ in kernel.send_response.call_args_list]
    assert messages[0] == ("stream", {"name": "stdout", "text": "debug output\n"})
    if status == "success":
        assert messages[-1][0] == "execute_result"
        assert not any(kind == "error" for kind, _ in messages)
        if diagnostics:
            assert messages[1] == ("stream", {"name": "stderr", "text": diagnostics})
    else:
        assert messages[-1][0] == "error"
        assert not any(kind == "execute_result" for kind, _ in messages)
        assert reply["ename"] == ("RocIncompleteInput" if status == "incomplete" else "RocError")
