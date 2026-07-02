const std = @import("std");
const iroc = @import("iroc");
const zmq = iroc.zmq;
const protocol = iroc.protocol;
const compiler_interface = iroc.compiler_interface;

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("time.h");
    @cInclude("sys/time.h");
    @cInclude("zmq.h");
});

/// Holds connection configuration parameters mapped from Jupyter.
const ConnectionInfo = struct {
    shellPort: u16,
    iopubPort: u16,
    stdinPort: u16,
    controlPort: u16,
    hbPort: u16,
    transport: []const u8,
    ip: []const u8,
    key: []const u8,
};

/// Generates a standard UUID version 4.
fn generateUuid(allocator: std.mem.Allocator) ![]const u8 {
    var uuidBuf: [36]u8 = undefined;
    var bytes: [16]u8 = undefined;
    var tv: c.timeval = undefined;
    _ = c.gettimeofday(&tv, null);
    const seed = @as(u64, @intCast(tv.tv_sec)) * 1_000_000 + @as(u64, @intCast(tv.tv_usec)) + @as(u64, @intCast(c.clock()));
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const uuidStr = try std.fmt.bufPrint(
        &uuidBuf,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
        },
    );
    return try allocator.dupe(u8, uuidStr);
}

/// Generates an ISO-8601 formatted UTC date string.
fn generateDate(allocator: std.mem.Allocator) ![]const u8 {
    var timeBuf: [64]u8 = undefined;
    var rawtime: c.time_t = undefined;
    _ = c.time(&rawtime);
    const timeinfo = c.gmtime(&rawtime);
    const timeLen = c.strftime(&timeBuf, timeBuf.len, "%Y-%m-%dT%H:%M:%SZ", timeinfo);
    return try allocator.dupe(u8, timeBuf[0..timeLen]);
}

/// Handles incoming messages on the control socket.
fn handleControlMessage(
    control: zmq.Socket,
    loopAllocator: std.mem.Allocator,
    key: []const u8,
) !void {
    var parsed = try protocol.recvMessage(control, loopAllocator, key);
    defer parsed.deinit();

    const msg = parsed.message;
    var delimIdx: usize = 0;
    for (parsed.rawFrames, 0..) |frame, idx| {
        if (std.mem.eql(u8, frame, "<IDS|MSG>")) {
            delimIdx = idx;
            break;
        }
    }
    const rawReqHeader = parsed.rawFrames[delimIdx + 2];

    if (std.mem.eql(u8, msg.header.msgType, "kernel_info_request")) {
        std.debug.print("Control: Received kernel_info_request\n", .{});

        const replyMsgId = try generateUuid(loopAllocator);
        const replyDate = try generateDate(loopAllocator);

        const replyContent = "{\"status\": \"ok\", \"protocol_version\": \"5.3\", \"implementation\": \"roc-dummy\", \"implementation_version\": \"0.1\", \"language_info\": {\"name\": \"roc\", \"version\": \"1.0\", \"mimetype\": \"text/x-roc\", \"file_extension\": \".roc\"}, \"banner\": \"Roc dummy kernel\"}";

        const replyMsg = protocol.Message{
            .identities = msg.identities,
            .header = protocol.Header{
                .msgId = replyMsgId,
                .username = msg.header.username,
                .session = msg.header.session,
                .msgType = "kernel_info_reply",
                .version = "5.3",
                .date = replyDate,
            },
            .parentHeader = .{ .raw = rawReqHeader },
            .metadata = .{ .raw = "{}" },
            .content = .{ .raw = replyContent },
        };

        try protocol.sendMessage(control, loopAllocator, key, replyMsg, false);
    }
}

/// Handles incoming execution and metadata requests on the shell socket.
fn handleShellMessage(
    shell: zmq.Socket,
    iopub: zmq.Socket,
    loopAllocator: std.mem.Allocator,
    key: []const u8,
    state: *compiler_interface.State,
    executionCount: *i64,
) !void {
    var parsed = try protocol.recvMessage(shell, loopAllocator, key);
    defer parsed.deinit();

    const msg = parsed.message;
    var delimIdx: usize = 0;
    for (parsed.rawFrames, 0..) |frame, idx| {
        if (std.mem.eql(u8, frame, "<IDS|MSG>")) {
            delimIdx = idx;
            break;
        }
    }
    const rawReqHeader = parsed.rawFrames[delimIdx + 2];

    if (std.mem.eql(u8, msg.header.msgType, "kernel_info_request")) {
        std.debug.print("Shell: Received kernel_info_request\n", .{});

        // Status rule: busy on iopub
        const busyMsgId = try generateUuid(loopAllocator);
        const busyDate = try generateDate(loopAllocator);
        const busyMsg = protocol.Message{
            .identities = &.{},
            .header = protocol.Header{
                .msgId = busyMsgId,
                .username = msg.header.username,
                .session = msg.header.session,
                .msgType = "status",
                .version = "5.3",
                .date = busyDate,
            },
            .parentHeader = .{ .raw = rawReqHeader },
            .metadata = .{ .raw = "{}" },
            .content = .{ .raw = "{\"execution_state\": \"busy\"}" },
        };
        try protocol.sendMessage(iopub, loopAllocator, key, busyMsg, true);

        // Send reply
        const replyMsgId = try generateUuid(loopAllocator);
        const replyDate = try generateDate(loopAllocator);
        const replyContent = "{\"status\": \"ok\", \"protocol_version\": \"5.3\", \"implementation\": \"roc-dummy\", \"implementation_version\": \"0.1\", \"language_info\": {\"name\": \"roc\", \"version\": \"1.0\", \"mimetype\": \"text/x-roc\", \"file_extension\": \".roc\"}, \"banner\": \"Roc dummy kernel\"}";

        const replyMsg = protocol.Message{
            .identities = msg.identities,
            .header = protocol.Header{
                .msgId = replyMsgId,
                .username = msg.header.username,
                .session = msg.header.session,
                .msgType = "kernel_info_reply",
                .version = "5.3",
                .date = replyDate,
            },
            .parentHeader = .{ .raw = rawReqHeader },
            .metadata = .{ .raw = "{}" },
            .content = .{ .raw = replyContent },
        };
        try protocol.sendMessage(shell, loopAllocator, key, replyMsg, false);

        // Status rule: idle on iopub
        const idleMsgId = try generateUuid(loopAllocator);
        const idleDate = try generateDate(loopAllocator);
        const idleMsg = protocol.Message{
            .identities = &.{},
            .header = protocol.Header{
                .msgId = idleMsgId,
                .username = msg.header.username,
                .session = msg.header.session,
                .msgType = "status",
                .version = "5.3",
                .date = idleDate,
            },
            .parentHeader = .{ .raw = rawReqHeader },
            .metadata = .{ .raw = "{}" },
            .content = .{ .raw = "{\"execution_state\": \"idle\"}" },
        };
        try protocol.sendMessage(iopub, loopAllocator, key, idleMsg, true);
        return;
    }

    if (std.mem.eql(u8, msg.header.msgType, "execute_request")) {
        // Immediately publish status: busy
        const busyMsgId = try generateUuid(loopAllocator);
        const busyDate = try generateDate(loopAllocator);
        const busyMsg = protocol.Message{
            .identities = &.{},
            .header = protocol.Header{
                .msgId = busyMsgId,
                .username = msg.header.username,
                .session = msg.header.session,
                .msgType = "status",
                .version = "5.3",
                .date = busyDate,
            },
            .parentHeader = .{ .raw = rawReqHeader },
            .metadata = .{ .raw = "{}" },
            .content = .{ .raw = "{\"execution_state\": \"busy\"}" },
        };
        try protocol.sendMessage(iopub, loopAllocator, key, busyMsg, true);

        // Process code execution
        const codeVal = msg.content.value.object.get("code") orelse return error.MissingCode;
        if (codeVal != .string) return error.InvalidCodeType;
        const code = codeVal.string;

        const trimmedCode = std.mem.trim(u8, code, " \t\r\n");
        std.debug.print("Shell: Received execute_request: '{s}'\n", .{trimmedCode});

        std.log.debug("Compiling cell: {s}", .{code});
        const runRes = try compiler_interface.compileAndRun(state, code);
        const res_len = if (runRes.result) |r| r.len else if (runRes.diagnostics) |d| d.len else 0;
        std.log.debug("compileAndRun returned result length: {}, stdout length: {}", .{ res_len, runRes.stdout.len });
        defer {
            if (runRes.result) |res| state.allocator.free(res);
            state.allocator.free(runRes.stdout);
            if (runRes.diagnostics) |diag| state.allocator.free(diag);
        }

        // 1. If .stdout is not empty, publish it to iopub as stream
        if (runRes.stdout.len > 0) {
            std.log.debug("Raw stdout string: {s}", .{runRes.stdout});
            const streamMsgId = try generateUuid(loopAllocator);
            const streamDate = try generateDate(loopAllocator);

            var streamJson = std.Io.Writer.Allocating.init(loopAllocator);
            defer streamJson.deinit();
            try std.json.Stringify.value(.{
                .name = "stdout",
                .text = runRes.stdout,
            }, .{}, &streamJson.writer);

            const streamMsg = protocol.Message{
                .identities = &.{},
                .header = protocol.Header{
                    .msgId = streamMsgId,
                    .username = msg.header.username,
                    .session = msg.header.session,
                    .msgType = "stream",
                    .version = "5.3",
                    .date = streamDate,
                },
                .parentHeader = .{ .raw = rawReqHeader },
                .metadata = .{ .raw = "{}" },
                .content = .{ .raw = streamJson.writer.buffered() },
            };
            try protocol.sendMessage(iopub, loopAllocator, key, streamMsg, true);
        }

        // 2. If .result or .diagnostics is not empty, publish it to iopub as execute_result
        if (runRes.result != null or runRes.diagnostics != null) {
            const val_to_send = runRes.result orelse runRes.diagnostics.?;
            std.log.debug("Raw result/diagnostic string: {s}", .{val_to_send});
            const resultMsgId = try generateUuid(loopAllocator);
            const resultDate = try generateDate(loopAllocator);

            var resultJson = std.Io.Writer.Allocating.init(loopAllocator);
            defer resultJson.deinit();
            try std.json.Stringify.value(.{
                .execution_count = executionCount.*,
                .data = .{
                    .@"text/plain" = val_to_send,
                },
                .metadata = .{},
            }, .{}, &resultJson.writer);

            const resultMsg = protocol.Message{
                .identities = &.{},
                .header = protocol.Header{
                    .msgId = resultMsgId,
                    .username = msg.header.username,
                    .session = msg.header.session,
                    .msgType = "execute_result",
                    .version = "5.3",
                    .date = resultDate,
                },
                .parentHeader = .{ .raw = rawReqHeader },
                .metadata = .{ .raw = "{}" },
                .content = .{ .raw = resultJson.writer.buffered() },
            };
            try protocol.sendMessage(iopub, loopAllocator, key, resultMsg, true);
        }

        // Send execute reply
        const replyMsgId = try generateUuid(loopAllocator);
        const replyDate = try generateDate(loopAllocator);
        const replyContent = try std.fmt.allocPrint(loopAllocator, "{{\n  \"status\": \"ok\",\n  \"execution_count\": {d},\n  \"user_expressions\": {{}}\n}}", .{executionCount.*});

        const replyMsg = protocol.Message{
            .identities = msg.identities,
            .header = protocol.Header{
                .msgId = replyMsgId,
                .username = msg.header.username,
                .session = msg.header.session,
                .msgType = "execute_reply",
                .version = "5.3",
                .date = replyDate,
            },
            .parentHeader = .{ .raw = rawReqHeader },
            .metadata = .{ .raw = "{}" },
            .content = .{ .raw = replyContent },
        };
        try protocol.sendMessage(shell, loopAllocator, key, replyMsg, false);

        // Publish status: idle
        const idleMsgId = try generateUuid(loopAllocator);
        const idleDate = try generateDate(loopAllocator);
        const idleMsg = protocol.Message{
            .identities = &.{},
            .header = protocol.Header{
                .msgId = idleMsgId,
                .username = msg.header.username,
                .session = msg.header.session,
                .msgType = "status",
                .version = "5.3",
                .date = idleDate,
            },
            .parentHeader = .{ .raw = rawReqHeader },
            .metadata = .{ .raw = "{}" },
            .content = .{ .raw = "{\"execution_state\": \"idle\"}" },
        };
        try protocol.sendMessage(iopub, loopAllocator, key, idleMsg, true);

        executionCount.* += 1;
    }
}

fn installKernel(allocator: std.mem.Allocator, io: std.Io, tmp_dir_path: []const u8) !void {
    const self_exe = try std.process.executablePathAlloc(io, allocator);

    const install_dir = try std.fs.path.join(allocator, &.{ tmp_dir_path, "roc_kernel_install" });
    defer allocator.free(install_dir);

    // Create directory
    std.Io.Dir.createDirAbsolute(io, install_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.Io.Dir.deleteDirAbsolute(io, install_dir) catch {};

    // Create file kernel.json inside it
    const kernel_json_path = try std.fs.path.join(allocator, &.{ install_dir, "kernel.json" });
    defer allocator.free(kernel_json_path);

    {
        var file = try std.Io.Dir.createFileAbsolute(io, kernel_json_path, .{});
        defer file.close(io);

        var json_buf = std.Io.Writer.Allocating.init(allocator);
        defer json_buf.deinit();

        try std.json.Stringify.value(.{
            .display_name = "Roc",
            .language = "roc",
            .argv = &[_][]const u8{ self_exe, "{connection_file}" },
        }, .{}, &json_buf.writer);

        try file.writePositionalAll(io, json_buf.writer.buffered(), 0);
    }
    defer std.Io.Dir.deleteFileAbsolute(io, kernel_json_path) catch {};

    // Run: jupyter kernelspec install <path_to_temp_dir> --user --name roc
    const res = std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "jupyter", "kernelspec", "install", install_dir, "--user", "--name", "roc" },
        .expand_arg0 = .expand,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("❌ Error: 'jupyter' command not found in PATH.\n", .{});
            std.debug.print("Please make sure Jupyter is installed and your virtual environment is active.\n", .{});
            return error.JupyterNotFound;
        },
        else => return err,
    };
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    switch (res.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("Failed to run jupyter kernelspec install. Code: {}\nStderr: {s}\n", .{ code, res.stderr });
                return error.JupyterInstallFailed;
            }
        },
        else => {
            std.debug.print("jupyter command terminated abnormally: {any}\nStderr: {s}\n", .{ res.term, res.stderr });
            return error.JupyterInstallFailed;
        },
    }

    std.debug.print("✅ Roc Jupyter Kernel installed successfully!\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--install")) {
        const tmp_dir_path = init.environ_map.get("TMPDIR") orelse init.environ_map.get("TEMP") orelse init.environ_map.get("TMP") orelse "/tmp";
        try installKernel(arena, init.io, tmp_dir_path);
        return;
    }

    if (args.len < 2) {
        std.debug.print("Usage: {s} <connection_file> or {s} --install\n", .{ args[0], args[0] });
        return error.MissingConnectionFile;
    }
    const connectionFilePath = args[1];

    std.debug.print("Reading connection file: {s}\n", .{connectionFilePath});
    const fd = std.posix.openat(std.posix.AT.FDCWD, connectionFilePath, .{ .ACCMODE = .RDONLY }, 0) catch |err| {
        std.debug.print("Failed to open connection file '{s}': {s}\n", .{ connectionFilePath, @errorName(err) });
        return err;
    };
    defer _ = c.close(fd);

    const maxSize = 10 * 1024 * 1024;
    var jsonContent = try arena.alloc(u8, maxSize);
    const bytesRead = try std.posix.read(fd, jsonContent);
    jsonContent = jsonContent[0..bytesRead];

    const parsedConnVal = std.json.parseFromSlice(std.json.Value, arena, jsonContent, .{}) catch |err| {
        std.debug.print("Failed to parse JSON connection file: {s}\n", .{@errorName(err)});
        return err;
    };
    defer parsedConnVal.deinit();
    const connObj = parsedConnVal.value.object;
    const conn = ConnectionInfo{
        .shellPort = @intCast(connObj.get("shell_port").?.integer),
        .iopubPort = @intCast(connObj.get("iopub_port").?.integer),
        .stdinPort = @intCast(connObj.get("stdin_port").?.integer),
        .controlPort = @intCast(connObj.get("control_port").?.integer),
        .hbPort = @intCast(connObj.get("hb_port").?.integer),
        .transport = try arena.dupe(u8, connObj.get("transport").?.string),
        .ip = try arena.dupe(u8, connObj.get("ip").?.string),
        .key = try arena.dupe(u8, connObj.get("key").?.string),
    };

    var ctx = try zmq.Context.init();
    defer ctx.deinit();

    var shell = try ctx.createSocket(.router);
    defer shell.deinit();

    var iopub = try ctx.createSocket(.pubSock);
    defer iopub.deinit();

    var control = try ctx.createSocket(.router);
    defer control.deinit();

    var hb = try ctx.createSocket(.rep);
    defer hb.deinit();

    var stdin = try ctx.createSocket(.router);
    defer stdin.deinit();

    var buf1: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    var buf3: [256]u8 = undefined;
    var buf4: [256]u8 = undefined;
    var buf5: [256]u8 = undefined;

    const shellEndpoint = try std.fmt.bufPrintZ(&buf1, "{s}://{s}:{d}", .{ conn.transport, conn.ip, conn.shellPort });
    try shell.bind(shellEndpoint);

    const iopubEndpoint = try std.fmt.bufPrintZ(&buf2, "{s}://{s}:{d}", .{ conn.transport, conn.ip, conn.iopubPort });
    try iopub.bind(iopubEndpoint);

    const controlEndpoint = try std.fmt.bufPrintZ(&buf3, "{s}://{s}:{d}", .{ conn.transport, conn.ip, conn.controlPort });
    try control.bind(controlEndpoint);

    const hbEndpoint = try std.fmt.bufPrintZ(&buf4, "{s}://{s}:{d}", .{ conn.transport, conn.ip, conn.hbPort });
    try hb.bind(hbEndpoint);

    const stdinEndpoint = try std.fmt.bufPrintZ(&buf5, "{s}://{s}:{d}", .{ conn.transport, conn.ip, conn.stdinPort });
    try stdin.bind(stdinEndpoint);

    std.debug.print("Jupyter dummy kernel started:\n", .{});
    std.debug.print("  - Shell (ROUTER)   bound to {s}\n", .{shellEndpoint});
    std.debug.print("  - IOPub (PUB)      bound to {s}\n", .{iopubEndpoint});
    std.debug.print("  - Control (ROUTER) bound to {s}\n", .{controlEndpoint});
    std.debug.print("  - Heartbeat (REP)  bound to {s}\n", .{hbEndpoint});
    std.debug.print("  - Stdin (ROUTER)   bound to {s}\n", .{stdinEndpoint});

    var state = try compiler_interface.initEnvironment(arena, init.io);
    defer compiler_interface.teardownEnvironment(&state);

    var executionCount: i64 = 1;

    while (true) {
        var loopArena = std.heap.ArenaAllocator.init(arena);
        defer loopArena.deinit();
        const loopAllocator = loopArena.allocator();

        var pollItems = [4]c.zmq_pollitem_t{
            .{
                .socket = shell.handle,
                .fd = 0,
                .events = c.ZMQ_POLLIN,
                .revents = 0,
            },
            .{
                .socket = control.handle,
                .fd = 0,
                .events = c.ZMQ_POLLIN,
                .revents = 0,
            },
            .{
                .socket = hb.handle,
                .fd = 0,
                .events = c.ZMQ_POLLIN,
                .revents = 0,
            },
            .{
                .socket = stdin.handle,
                .fd = 0,
                .events = c.ZMQ_POLLIN,
                .revents = 0,
            },
        };

        const rc = c.zmq_poll(&pollItems[0], 4, 50);
        if (rc < 0) {
            const errNo = c.zmq_errno();
            if (errNo != c.EINTR) {
                _ = c.usleep(10 * 1000);
            }
            continue;
        }
        if (rc == 0) {
            continue;
        }

        // 1. Heartbeat socket (REP)
        if ((pollItems[2].revents & c.ZMQ_POLLIN) != 0) {
            const parts = hb.recvMultipart(loopAllocator) catch |err| {
                std.log.err("Heartbeat recv failed: {}", .{err});
                continue;
            };
            defer {
                for (parts) |part| loopAllocator.free(part);
                loopAllocator.free(parts);
            }
            hb.sendMultipart(parts) catch |err| {
                std.log.err("Heartbeat send failed: {}", .{err});
            };
            continue;
        }

        // 2. Control socket (ROUTER)
        if ((pollItems[1].revents & c.ZMQ_POLLIN) != 0) {
            handleControlMessage(control, loopAllocator, conn.key) catch |err| {
                std.log.err("Control socket process error: {}", .{err});
            };
            continue;
        }

        // 3. Stdin socket (ROUTER)
        if ((pollItems[3].revents & c.ZMQ_POLLIN) != 0) {
            const parts = stdin.recvMultipart(loopAllocator) catch |err| {
                std.log.err("Stdin recv failed: {}", .{err});
                continue;
            };
            for (parts) |part| loopAllocator.free(part);
            loopAllocator.free(parts);
            continue;
        }

        // 4. Shell socket (ROUTER)
        if ((pollItems[0].revents & c.ZMQ_POLLIN) != 0) {
            handleShellMessage(shell, iopub, loopAllocator, conn.key, &state, &executionCount) catch |err| {
                std.log.err("Shell socket process error: {}", .{err});
            };
            continue;
        }
    }
}
