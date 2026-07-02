const std = @import("std");

/// The evaluation environment state holding the Roc compiler REPL child process.
pub const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    session_id: []const u8,
};

/// The execution result returned by compileAndRun.
pub const ExecutionResult = struct {
    result: ?[]const u8,
    stdout: []const u8,
    diagnostics: ?[]const u8,
};

/// Initializes and returns a new evaluation state, spinning up the Roc REPL child process.
pub fn initEnvironment(allocator: std.mem.Allocator, io: std.Io) !State {
    const argv = [_][]const u8{ "/Users/ageron/dev/software/roc_new_compiler/roc", "repl", "--rpc" };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .pipe,
    });
    errdefer {
        _ = child.wait(io) catch {};
    }

    // Write {"method": "repl.start"} to stdin
    const start_payload = "{\"method\": \"repl.start\"}\n";
    try child.stdin.?.writeStreamingAll(io, start_payload);

    // Read the first line of JSON from stdout
    var buf: [4096]u8 = undefined;
    var reader = child.stdout.?.reader(io, &buf);
    const line = (try reader.interface.takeDelimiter('\n')) orelse return error.EmptyReplResponse;

    // Parse it to extract "session_id"
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    const session_id_val = parsed.value.object.get("session_id") orelse return error.MissingSessionId;
    if (session_id_val != .string) return error.InvalidSessionIdType;
    const session_id = try allocator.dupe(u8, session_id_val.string);

    return State{
        .allocator = allocator,
        .io = io,
        .child = child,
        .session_id = session_id,
    };
}

/// Clears all variable declarations from the evaluation state by stopping and restarting the REPL.
pub fn resetEnvironment(state: *State) void {
    const stop_payload = std.fmt.allocPrint(state.allocator, "{{\"method\": \"repl.stop\", \"params\": {{\"session_id\": \"{s}\"}}}}\n", .{state.session_id}) catch |err| {
        std.log.err("Failed to format repl.stop request: {}", .{err});
        return;
    };
    defer state.allocator.free(stop_payload);

    state.child.stdin.?.writeStreamingAll(state.io, stop_payload) catch {};
    if (state.child.stdin) |stdin| {
        stdin.close(state.io);
        state.child.stdin = null;
    }
    if (state.child.stdout) |stdout| {
        stdout.close(state.io);
        state.child.stdout = null;
    }
    _ = state.child.wait(state.io) catch {};
    state.allocator.free(state.session_id);

    // Spawn a new child process
    const argv = [_][]const u8{ "/Users/ageron/dev/software/roc_new_compiler/roc", "repl", "--rpc" };
    state.child = std.process.spawn(state.io, .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .pipe,
    }) catch |err| {
        std.log.err("Failed to spawn REPL on reset: {}", .{err});
        @panic("REPL spawn failed");
    };

    const start_payload = "{\"method\": \"repl.start\"}\n";
    state.child.stdin.?.writeStreamingAll(state.io, start_payload) catch |err| {
        std.log.err("Failed to write repl.start on reset: {}", .{err});
        @panic("REPL start failed");
    };

    var buf: [4096]u8 = undefined;
    var reader = state.child.stdout.?.reader(state.io, &buf);
    const line = reader.interface.takeDelimiter('\n') catch |err| {
        std.log.err("Failed to read repl.start response on reset: {}", .{err});
        @panic("REPL read failed");
    } orelse {
        @panic("REPL response empty");
    };

    const parsed = std.json.parseFromSlice(std.json.Value, state.allocator, line, .{}) catch |err| {
        std.log.err("Failed to parse repl.start response on reset: {}", .{err});
        @panic("REPL parse failed");
    };
    defer parsed.deinit();

    const session_id_val = parsed.value.object.get("session_id") orelse {
        @panic("REPL response missing session_id");
    };
    state.session_id = state.allocator.dupe(u8, session_id_val.string) catch |err| {
        std.log.err("Failed to dupe session_id on reset: {}", .{err});
        @panic("REPL dupe failed");
    };
}

/// Disposes of the child process REPL session.
pub fn teardownEnvironment(state: *State) void {
    const stop_payload = std.fmt.allocPrint(state.allocator, "{{\"method\": \"repl.stop\", \"params\": {{\"session_id\": \"{s}\"}}}}\n", .{state.session_id}) catch |err| {
        std.log.err("Failed to format repl.stop request: {}", .{err});
        return;
    };
    defer state.allocator.free(stop_payload);

    state.child.stdin.?.writeStreamingAll(state.io, stop_payload) catch {};
    if (state.child.stdin) |stdin| {
        stdin.close(state.io);
        state.child.stdin = null;
    }
    if (state.child.stdout) |stdout| {
        stdout.close(state.io);
        state.child.stdout = null;
    }
    _ = state.child.wait(state.io) catch {};
    state.allocator.free(state.session_id);
}

/// Evaluates a block of code by executing it inside the Roc REPL child process.
pub fn compileAndRun(state: *State, code: []const u8) !ExecutionResult {
    var req_buf = std.Io.Writer.Allocating.init(state.allocator);
    defer req_buf.deinit();

    try std.json.Stringify.value(.{
        .method = "repl.evaluate",
        .params = .{
            .session_id = state.session_id,
            .code = code,
        },
    }, .{}, &req_buf.writer);

    try req_buf.writer.writeByte('\n');

    // Write to child stdin
    try state.child.stdin.?.writeStreamingAll(state.io, req_buf.writer.buffered());

    // Read response line from stdout
    const read_buf = try state.allocator.alloc(u8, 256 * 1024);
    defer state.allocator.free(read_buf);

    var reader = state.child.stdout.?.reader(state.io, read_buf);
    const line = (try reader.interface.takeDelimiter('\n')) orelse return error.EmptyReplResponse;

    // Parse response
    const parsed = try std.json.parseFromSlice(std.json.Value, state.allocator, line, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;

    const result_val = obj.get("result");
    const stdout_val = obj.get("stdout");
    const diagnostics_val = obj.get("diagnostics");

    const result = if (result_val) |v| switch (v) {
        .string => |s| try state.allocator.dupe(u8, s),
        else => null,
    } else null;

    const stdout_str = if (stdout_val) |v| switch (v) {
        .string => |s| try state.allocator.dupe(u8, s),
        else => try state.allocator.dupe(u8, ""),
    } else try state.allocator.dupe(u8, "");

    const diagnostics = if (diagnostics_val) |v| switch (v) {
        .string => |s| try state.allocator.dupe(u8, s),
        else => null,
    } else null;

    return ExecutionResult{
        .result = result,
        .stdout = stdout_str,
        .diagnostics = diagnostics,
    };
}

/// Returns a generic parse error message string.
pub fn handleParseError() ![]const u8 {
    return "Parse error";
}

/// Returns a generic type error message string.
pub fn handleTypeError() ![]const u8 {
    return "Type error";
}

/// Placeholder function to support code autocompletion.
pub fn autocomplete(state: *State, prefix: []const u8) ![]const u8 {
    _ = state;
    _ = prefix;
    return &.{};
}

/// Placeholder function to inspect code symbols.
pub fn inspect(state: *State, symbol: []const u8) ![]const u8 {
    _ = state;
    _ = symbol;
    return "";
}

test "compiler_interface basic functionality" {
    const allocator = std.testing.allocator;
    var threadedIo = std.Io.Threaded.init(allocator, .{});
    defer threadedIo.deinit();
    const io = threadedIo.io();

    var state = try initEnvironment(allocator, io);
    defer teardownEnvironment(&state);

    const r1 = try compileAndRun(&state, "x = 42");
    defer {
        if (r1.result) |res| allocator.free(res);
        allocator.free(r1.stdout);
        if (r1.diagnostics) |diag| allocator.free(diag);
    }
    try std.testing.expect(r1.result != null or r1.diagnostics != null);
}
