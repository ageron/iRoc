# iRoc — a Roc kernel for Jupyter

iRoc is a Python Jupyter kernel built on `ipykernel`. It runs a persistent
`roc repl --formatter` subprocess; Roc evaluates every cell. Python handles
notebook integration and forwards the formatter's outputs.

## Installation

Requirements: Python 3.10 or newer, Jupyter Notebook or JupyterLab, and a Roc
compiler supporting `roc repl --formatter`. Zig and system ZeroMQ development
libraries are no longer required to install iRoc.

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

Bindings persist between cells. Diagnostics become Jupyter errors; subsequent
cells can still use definitions accepted before an error. `dbg` output is sent
as stdout after the formatter finishes evaluating the cell.

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
| `StructuredJson(Json.to_str({name: "Roc", scores: [1.I64, 2.I64]}))` | `application/json` |

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
The formatter replies with `result`, `stdout`, and `diagnostics` strings plus a
`data` list of `{mime, encoding, value}` entries. The kernel converts entries
with `encoding: "json"` into JSON values; integers and decimals retain their
precision on the Jupyter wire. Neither the Roc compiler nor its CLI contains
this JSON-specific protocol.

Jupyter's transport, message signatures, heartbeat, status messages, and request
dispatch come from `ipykernel`. The kernel does not interpret Roc or scrape REPL
prompts. The Roc compiler and its build process are unchanged by this migration.
