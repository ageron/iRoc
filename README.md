# iRoc — a Roc kernel for Jupyter

iRoc is a Python Jupyter kernel built on `ipykernel`. It runs a persistent
`roc repl --formatter` subprocess; Roc evaluates every cell. Python handles
notebook integration and forwards the formatter's outputs.

## Installation

Requirements: Python 3.10 or newer, Jupyter Notebook or JupyterLab, and a Roc
compiler supporting the `Evaluate`/`Reply` formatter API with
`encode(input, response)` and explicit execution status. Earlier formatter
compiler builds are incompatible with this version of iRoc. Zig and system
ZeroMQ development libraries are no longer required to install iRoc.

The Colab setup downloads the [October 12 compiler release](https://github.com/ageron/roc/releases/download/roc-iroc-2026-10-12/roc-iroc-linux-x86_64.zip)
by default. To use another compatible Linux x86_64 ZIP containing
`roc-iroc-linux-x86_64`, set `IROC_COMPILER_URL` before running setup.

Install from this checkout in your chosen Python environment:

```sh
python -m pip install .
python -m iroc install --user --roc /absolute/path/to/roc
```

Then start Jupyter and select **Roc**. The kernelspec records the Python
interpreter used for installation, so that environment must remain available.
Omit `--roc` to use `IROC_ROC` or find `roc` on the kernel process's `PATH`.
Use `--sys-prefix` instead of `--user` to register in the Python environment,
or `--prefix /path` for a custom Jupyter installation prefix.
The `iroc` console command supports the same arguments as `python -m iroc`.

### Migrating from the Zig kernel

The installation command replaces the existing `roc` kernelspec. In JupyterLab,
shut down the old kernel from the Running panel (or use **Shut Down Kernel**),
then reopen the notebook and select **Roc**. **Restart Kernel** alone reuses the
old kernel manager and may launch the previous Zig executable again. Existing notebooks still use the
same kernel name. The formatter is bundled in the Python package; no separate
formatter file or native iRoc executable needs to be copied.

## Development and tests

With [uv](https://docs.astral.sh/uv/):

```sh
uv sync
uv run python -m iroc install --user --roc /absolute/path/to/roc
uv run pytest
uv run python tests/test_formatter.py --roc /absolute/path/to/roc
uv run python tests/test_jupyter.py --roc /absolute/path/to/roc
uv run python tests/test_lifecycle.py --roc /absolute/path/to/roc
uv run python tests/test_run_all.py --roc /absolute/path/to/roc
uv build
```

`uv.lock` records the development dependencies. Without uv, use
`python -m pip install -e . pytest`, then run the same Python commands.
The tests cover response validation, process failures, exact JSON numbers,
stateful evaluation, rich output, multiline strings, large messages, silent
execution, interruption, restart, graceful shutdown, and cancellation of queued
cells after an error.

## Behavior

Use `:t <identifier>` to inspect a binding's type, just as in the terminal REPL:

```roc
s = "Hello"
:t s
```

This displays `s : Str`. A type query can share a cell with definitions or be
run in a later cell; it does not evaluate the binding.

Bindings persist between cells. Top-level statements run in order and stop at the first
failure or incomplete statement. Earlier accepted definitions remain available;
a rejected definition is rolled back and subsequent statements are skipped.
Incomplete source is not buffered: submit a new complete cell to finish it.

The last successful expression supplies the result, even if followed by a
definition, `expect`, `for`, or `while` statement. A standalone `dbg` produces
`{}` as its result as well as debug output. A successful `:t` query replaces the
result with type text. Cells containing
only definitions have no displayed result. After a failed or incomplete cell,
iRoc reports a Jupyter error and suppresses its result display; earlier accepted
definitions remain usable. "Run All" stops on either status. Successful
responses may contain diagnostic text, which is displayed on stderr without
turning the execution into an error. `dbg` output is sent as stdout after the
formatter finishes evaluating the cell.

Interrupting execution stops the Roc process and clears its definitions. The
error explicitly reports this; rerun defining cells afterward. The next cell
starts a fresh Roc process. A compiler-process failure similarly reports the
failure and discards the old scope. Restarting the kernel also clears its state.
Roc completion, inspection, stdin prompts, and Jupyter `user_expressions` are
not implemented. Code completeness is reported as unknown rather than guessed.

### Rich output

Return one of these tags as the cell's last expression:

| Roc expression | Jupyter MIME type |
| --- | --- |
| `Html("<b>Hello</b>")` | `text/html` |
| `Markdown("# Title\n**Hello**")` | `text/markdown` |
| `Svg("<svg xmlns=\"http://www.w3.org/2000/svg\"><circle cx=\"25\" cy=\"25\" r=\"20\"/></svg>")` | `image/svg+xml` |
| `Json(Json.to_str({name: "Roc", scores: [1.I64, 2.I64]}))` | `application/json` |

All four tags take exactly one `Str`. Use Markdown for math: `$...$` for inline
math and `$$...$$` for display math in Jupyter. For example:

```roc
Markdown("**Einstein** found that $E = mc^2$.")
Markdown("$$E = mc^2$$")
Markdown("$$\\frac{1}{2}$$")
```

Escape backslashes in Roc strings as shown above.

Structured JSON is published as an actual JSON value, including nested objects,
arrays, booleans and null, with numeric text preserved. Invalid JSON or an invalid
display payload produces a Jupyter error; subsequent cells remain usable.

Every displayed result also includes its inspected `text/plain` representation.
Only actual top-level structural tags activate rich output. Strings that look
like tags, nested tags, nominal wrappers, and unrelated tags stay plain text.
The compiler exposes tag information independently of the wire protocol; the Roc
formatter owns these display conventions. Rendering depends on the notebook
frontend's MIME support and notebook trust settings.

## Architecture

- `iroc/kernel.py`: `ipykernel` adapter for execution, outputs, and lifecycle.
- `iroc/repl.py`: persistent subprocess, formatter framing, and MIME decoding.
- `iroc/json-repl-formatter.roc`: Roc module implementing `decode` and `encode`.
- `iroc/__main__.py`: kernel launcher and kernelspec installer.

The kernel sends one JSON line per cell: `{"code":"x = 40\nx + 2"}`.
The formatter replies with a `status` string (`"success"`, `"incomplete"`, or
`"failure"`), `result`, `stdout`, and `diagnostics` strings, and a `data` list of
`{mime, encoding, value}` entries. Status, not the presence of diagnostics,
determines execution success. Malformed protocol requests and invalid rich
payloads produce `"failure"`. Missing or unknown status is a protocol error.

The Roc formatter implements `decode : Str -> [Evaluate(Str), Reply(Str)]` and
`encode : Str, Response -> Str`. `Reply` returns a protocol response without
execution; `encode` gets the original input line (excluding LF), so a custom
formatter can recover IDs or display preferences without mutable formatter
state. Its `Response` contains a structural `Success`, `Incomplete`, or `Failure`
status plus `result`, `stdout`, `diagnostics`, and semantic `value` fields.
The compiler extracts actual top-level tags; it never parses inspection text.
A formatter-defined tag carrying one serialized string can describe a display
bundle without adding recursive reflection to the compiler.

User-code failures keep the Roc process usable. Invalid formatter modules,
formatter crashes, replies containing literal LF, unsupported host effects,
and operational failures terminate it. EOF normally closes it successfully;
iRoc expects one complete reply for each submitted request.

The kernel converts entries with `encoding: "json"` into JSON values; integers and decimals retain their
precision on the Jupyter wire. Neither the Roc compiler nor its CLI contains
this JSON-specific protocol.

Jupyter's transport, message signatures, heartbeat, status messages, and request
dispatch come from `ipykernel`. The kernel does not interpret Roc or scrape REPL
prompts. The Roc compiler and its build process are unchanged by this migration.
