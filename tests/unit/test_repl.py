import json
import sys

import pytest

from iroc.repl import ReplError, RocRepl, decode_response


def reply(**fields):
    return json.dumps(
        {"result": "", "stdout": "", "diagnostics": "", "data": [], **fields}
    )


def test_structured_json_and_invalid_json():
    large = 123456789012345678901234567890
    response = decode_response(
        reply(
            data=[
                {
                    "mime": "application/json",
                    "encoding": "json",
                    "value": json.dumps({"n": large}),
                }
            ]
        )
    )
    assert response["bundle"]["application/json"]["n"] == large
    for invalid in ["bad json", "NaN", "Infinity", "-Infinity"]:
        response = decode_response(
            reply(
                data=[
                    {"mime": "application/json", "encoding": "json", "value": invalid}
                ]
            )
        )
        assert "valid JSON" in response["diagnostics"]


@pytest.mark.parametrize(
    "line",
    [
        "{}",
        "[]",
        "not json",
        '{"result": 42}',
        reply(data=[{}]),
        reply(data=[{"mime": "text/html", "encoding": "bad", "value": ""}]),
    ],
)
def test_malformed_protocol(line):
    with pytest.raises(ValueError):
        decode_response(line)


def test_missing_compiler(tmp_path):
    repl = RocRepl(str(tmp_path / "missing"))
    with pytest.raises(ReplError, match="Could not start Roc"):
        repl.execute("42")
    assert repl.process is None and repl.stderr is None


@pytest.mark.skipif(
    sys.platform == "win32", reason="Executable script fixture uses a POSIX shebang"
)
def test_dead_process_and_large_stderr_recovery(tmp_path):
    compiler = tmp_path / "fake-roc"
    compiler.write_text(
        f'#!{sys.executable}\nimport sys\nsys.stderr.write("failure " * 20000)\nsys.exit(1)\n'
    )
    compiler.chmod(0o755)
    repl = RocRepl(str(compiler))
    with pytest.raises(ReplError, match="state was cleared") as failure:
        repl.execute("42")
    assert "failure" in str(failure.value)
    assert repl.process is None and repl.stderr is None
    compiler.write_text(
        f"#!{sys.executable}\nimport sys\nfor line in sys.stdin:\n print({reply()!r}, flush=True)\n"
    )
    try:
        assert repl.execute("42")["diagnostics"] == ""
        process = repl.process
    finally:
        repl.close()
    assert process.poll() is not None


def test_json_decimal_wire_precision():
    from iroc.kernel import pack_message

    number = "0.123456789012345678901234567890"
    response = decode_response(
        reply(data=[{"mime": "application/json", "encoding": "json", "value": number}])
    )
    assert number.encode() in pack_message(response["bundle"])
