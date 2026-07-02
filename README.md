# iRoc - A Roc kernel for Jupyter project

## Installation

To install the Roc Jupyter Kernel on your system:

### Prerequisites
- The **Roc compiler** must be installed and available in your system `$PATH` (ensure `roc` is runnable).
- **Python** and **Jupyter** (Jupyter Notebook or JupyterLab) must be installed.

### Step 1: Download or build the binary
Clone this repository and build the binary:
```bash
zig build
```
The compiled binary will be placed at `zig-out/bin/roc_jupyter_kernel`.

### Step 2: Register the kernel with Jupyter
Run the binary with the `--install` flag:
```bash
./zig-out/bin/roc_jupyter_kernel --install
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
Expected output:
```text
Build Summary: 5/5 steps succeeded; 7/7 tests passed
test success
+- run test 6 pass (6 total) 69ms MaxRSS:5M
|  +- compile test Debug native cached 42ms MaxRSS:34M
+- run test 1 pass (1 total) 1s MaxRSS:2M
   +- compile test Debug native success 992ms MaxRSS:299M
```

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
* **REPL Child Process**: Spawns a persistent `roc repl --rpc` subprocess, managing the session with the `repl.start`, `repl.evaluate`, and `repl.stop` JSON-RPC methods.
* **Request Evaluation**: Intercepts cell execution requests and evaluates them within the running REPL session. Output and diagnostics (errors or compiler warnings) are collected from the RPC JSON responses.
* **Jupyter Streams & Outputs**: 
  - Standard output (`stdout`) from the evaluated code is routed to the `iopub` socket as a `stream` message.
  - Evaluation results and compiler diagnostics are serialized using strict JSON stringification and published to the `iopub` socket as `execute_result` messages.
