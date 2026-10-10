# iRoc - A Roc kernel for Jupyter project

## Installation

To install the Roc Jupyter Kernel on your system:

### Prerequisites
- The **Roc compiler** must be installed and available in your system `$PATH` with support for `roc repl --formatter` (ensure `roc` is runnable).
- **ZeroMQ** development libraries (`brew install zeromq` on macOS).
- **Zig 0.16.0** for the kernel (the Roc compiler has its own toolchain requirements).
- **Python** and **Jupyter** (Jupyter Notebook or JupyterLab) must be installed.

### Step 1: Download or build the binary
Clone this repository and build the binary:
```bash
zig build
```
The compiled binary and `json-repl-formatter.roc` are installed together in `zig-out/bin/`. Keep both files together when moving the kernel.

### Step 2: Register the kernel with Jupyter
Run the binary with the `--install` flag:
```bash
./zig-out/bin/iroc --install
```
This automatically generates the required `kernel.json` config and registers the spec with Jupyter.

> [!NOTE]
> If your Jupyter installation resides in a virtual environment (e.g. conda, virtualenv), make sure to activate that environment before running the install command.

### Step 3: Launch Jupyter
Start Jupyter and create a new notebook selecting the "Roc" kernel:
```bash
jupyter notebook
# or
jupyter lab
```

---

## Build and Testing

### Run the App
To compile and run the application (expects connection file path as argument):
```bash
zig build run -- connection_file.json
```

### Run Tests
To execute all unit and integration tests (including the ROUTER <-> DEALER message transmission tests and the `handleExecuteRequest` logic tests):
```bash
zig build test --summary all
```
The suite includes the compiler integration test, which checks persistent
bindings, multiline cells, diagnostics, recovery, and reset against the selected
Roc executable.

---

## File Layout

* **[build.zig](build.zig)**: Configured to link against the system's `libzmq` and `libc`. It automatically searches standard Homebrew include/lib paths on macOS.
* **[src/zmq.zig](src/zmq.zig)**: Low-level C-interop wrapper around standard ZeroMQ calls (contexts, sockets, options, and multipart messages).
* **[src/protocol.zig](src/protocol.zig)**: Implementation of the Jupyter JSON Wire Protocol structure, HMAC-SHA256 signature computation, and ZMQ message transmission functions.
* **[src/root.zig](src/root.zig)**: Package root exporting `zmq` and `protocol` modules and registering their tests.
* **[src/main.zig](src/main.zig)**: Application entrypoint that parses the Jupyter connection file, binds ROUTER (shell) and PUB (iopub) sockets, maintains the environment state, and runs the kernel execution request loop.

---

## Architecture and Design

### 1. ZeroMQ Wrapper (`src/zmq.zig`)
The ZeroMQ wrapper exposes:
* **Context**: Handles context creation (`zmq_ctx_new`) and clean termination (`zmq_ctx_term`).
* **Socket**: Wraps socket creation, socket binding, connections, single-part/multipart transmission, and socket option configuration.
* **Msg**: Wraps `zmq_msg_t` for memory-efficient dynamic receiving of frames.
* **Generic Options**: A compile-time options getter/setter utilizing Zig's reflection system (`@typeInfo`) to transparently configure either byte slice (e.g., `ZMQ_SUBSCRIBE`) or numeric (e.g., `ZMQ_RCVMORE`) options.

### 2. Jupyter Wire Protocol (`src/protocol.zig`)
* **Header & Message Structures**: Standard Zig structs matching the Jupyter v5.3 protocol fields. Nested JSON structures (like `parent_header`, `metadata`, and `content`) use `std.json.Value` to prevent parsing failures on variable payloads.
* **HMAC-SHA256 Signatures**: Computes signatures using Zig's native `std.crypto.auth.hmac.sha2.HmacSha256` over the concatenated `header`, `parent_header`, `metadata`, and `content` fields. The final signature is hex-encoded using `std.fmt.bytesToHex`.
* **ZMQ Message Helpers**: High-level `sendMessage` and `recvMessage` functions that serialize/deserialize complete, signature-validated Jupyter messages over ZeroMQ sockets.
* **Resource Safety**: Uses a `std.heap.ArenaAllocator` inside the `ParsedMessage` struct to manage the lifetime of parsed JSON values and duplicate ZMQ frames.

### 3. Roc REPL Integration (`src/main.zig` & `src/compiler_interface.zig`)
* **Connection File Parsing**: Parses the Jupyter JSON connection file path passed via command line, extracting `shell_port`, `iopub_port`, `transport`, `ip`, and the HMAC `key`.
* **REPL Child Process**: Spawns a persistent `roc repl --formatter <path>/json-repl-formatter.roc` subprocess using `roc` from `$PATH`. Each kernel owns one REPL scope; EOF closes it and restarting clears it.
* **Request Evaluation**: Intercepts cell execution requests and evaluates them within the running REPL session. Output and diagnostics (errors or compiler warnings) are collected from the formatter JSON responses.
* **Jupyter Streams & Outputs**: 
  - Standard output (`stdout`) from the evaluated code is routed to the `iopub` socket as a `stream` message.
  - Evaluation results are published as `execute_result` messages. Diagnostics are published as Jupyter `error` messages and an `execute_reply` with error status.

### Formatter protocol

The kernel sends one JSON line per cell: `{"code":"x = 40\nx + 2"}`.
The Roc formatter uses built-in `Json.parse` and `Json.to_str` to produce replies
with string fields `result`, `stdout`, and `diagnostics`, plus a `data` list of
`{mime, encoding, value}` entries. `encoding` is `text` or `json`; `value` is a
string, decoded by the kernel for JSON entries. Empty result/diagnostic strings mean no
value or diagnostic. Malformed requests receive a diagnostic reply without
changing the REPL state. Multiline source and strings are escaped by the JSON
codec. Neither the compiler nor its CLI contains this JSON protocol.

Run the integration tests against a specific compiler with:

```sh
zig build test -Droc=/absolute/path/to/roc
```

### Rich output

Return one of these tags as the cell's last expression:

| Roc expression | Jupyter MIME type |
| --- | --- |
| `Html("<b>Hello</b>")` | `text/html` |
| `Markdown("# Title\n**Hello**")` | `text/markdown` |
| `Svg("<svg xmlns=\"http://www.w3.org/2000/svg\"><circle cx=\"25\" cy=\"25\" r=\"20\"/></svg>")` | `image/svg+xml` |
| `Latex("$$x^2 + y^2 = z^2$$")` | `text/latex` |
| `StructuredJson(Json.to_str({name: "Roc", scores: [1.I64, 2.I64]}))` | `application/json` |

All five tags take exactly one `Str`. For LaTeX, include math delimiters and
escape backslashes in Roc strings, e.g. `Latex("$$\\frac{1}{2}$$")`.
Structured JSON is published as an actual JSON value, including nested objects,
arrays, booleans and null, with numeric text preserved. Invalid JSON or an invalid
display payload produces a Jupyter error; subsequent cells remain usable.

Every displayed result also includes its inspected `text/plain` representation.
Only actual top-level structural tags activate rich output. Strings that look
like tags, nested tags, nominal wrappers, and unrelated tags stay plain text.
The compiler exposes tag information independently of the wire protocol; the Roc
formatter owns these five display conventions. Rendering depends on the notebook
frontend's MIME support and notebook trust settings.

Additional end-to-end checks:

```sh
python3 tests/test_formatter.py --roc /absolute/path/to/roc
uv run --with jupyter-client --with pyzmq python tests/test_jupyter.py --roc /absolute/path/to/roc
```
