const std = @import("std");

/// One kernel owns one persistent formatter REPL and one buffered response reader.
pub const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    reader: std.Io.File.Reader,
    read_buffer: []u8,
    roc_path: []const u8,
    formatter_path: []const u8,
};

pub const ExecutionResult = struct {
    result: ?[]const u8,
    stdout: []const u8,
    diagnostics: ?[]const u8,
};

/// The installed formatter lives beside the kernel executable.
pub fn initEnvironment(allocator: std.mem.Allocator, io: std.Io) !State {
    const executable = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(executable);
    const formatter = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(executable).?, "json-repl-formatter.roc" });
    defer allocator.free(formatter);
    return initWithPaths(allocator, io, "roc", formatter);
}

/// Explicit paths support custom compiler installations and integration tests.
pub fn initWithPaths(allocator: std.mem.Allocator, io: std.Io, roc_path: []const u8, formatter_path: []const u8) !State {
    const roc = try allocator.dupe(u8, roc_path);
    errdefer allocator.free(roc);
    const formatter = try allocator.dupe(u8, formatter_path);
    errdefer allocator.free(formatter);
    const buffer = try allocator.alloc(u8, 4096);
    errdefer allocator.free(buffer);
    var child = try std.process.spawn(io, .{
        .argv = &.{ roc, "repl", "--formatter", formatter },
        .expand_arg0 = .expand,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    return .{
        .allocator = allocator,
        .io = io,
        .child = child,
        .reader = child.stdout.?.reader(io, buffer),
        .read_buffer = buffer,
        .roc_path = roc,
        .formatter_path = formatter,
    };
}

/// Restart with the same compiler and formatter, clearing all definitions.
pub fn resetEnvironment(state: *State) !void {
    const replacement = try initWithPaths(state.allocator, state.io, state.roc_path, state.formatter_path);
    teardownEnvironment(state);
    state.* = replacement;
}

/// EOF ends the formatter REPL; no wire-format-specific shutdown is needed.
pub fn teardownEnvironment(state: *State) void {
    if (state.child.stdin) |stdin| stdin.close(state.io);
    state.child.stdin = null;
    if (state.child.stdout) |stdout| stdout.close(state.io);
    state.child.stdout = null;
    _ = state.child.wait(state.io) catch {};
    state.allocator.free(state.read_buffer);
    state.allocator.free(state.roc_path);
    state.allocator.free(state.formatter_path);
}

pub fn compileAndRun(state: *State, code: []const u8) !ExecutionResult {
    var request = std.Io.Writer.Allocating.init(state.allocator);
    defer request.deinit();
    try std.json.Stringify.value(.{ .code = code }, .{}, &request.writer);
    try request.writer.writeByte('\n');
    try state.child.stdin.?.writeStreamingAll(state.io, request.writer.buffered());

    var response = std.Io.Writer.Allocating.init(state.allocator);
    defer response.deinit();
    _ = state.reader.interface.streamDelimiter(&response.writer, '\n') catch |err| switch (err) {
        error.EndOfStream => return error.EmptyReplResponse,
        else => return err,
    };
    state.reader.interface.toss(1);
    const Response = struct { result: []const u8, stdout: []const u8, diagnostics: []const u8 };
    const parsed = try std.json.parseFromSlice(Response, state.allocator, response.writer.buffered(), .{});
    defer parsed.deinit();
    const result = if (parsed.value.result.len > 0) try state.allocator.dupe(u8, parsed.value.result) else null;
    errdefer if (result) |bytes| state.allocator.free(bytes);
    const stdout = try state.allocator.dupe(u8, parsed.value.stdout);
    errdefer state.allocator.free(stdout);
    const diagnostics = if (parsed.value.diagnostics.len > 0) try state.allocator.dupe(u8, parsed.value.diagnostics) else null;
    return .{ .result = result, .stdout = stdout, .diagnostics = diagnostics };
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

test "formatter REPL preserves state, reports errors, and resets" {
    const allocator = std.testing.allocator;
    const options = @import("compiler_test_options");
    var state = try initWithPaths(allocator, std.testing.io, options.roc_path, options.formatter_path);
    defer teardownEnvironment(&state);
    const cases = [_]struct { code: []const u8, result: ?[]const u8, error_expected: bool = false }{
        .{ .code = "x = 42.I64", .result = null },
        .{ .code = "x + 1", .result = "43" },
        .{ .code = "unknown_name", .result = null, .error_expected = true },
        .{ .code = "x", .result = "42" },
        .{ .code = "y = 2.I64\nx + y", .result = "44" },
    };
    for (cases) |case| {
        const result = try compileAndRun(&state, case.code);
        defer {
            if (result.result) |bytes| allocator.free(bytes);
            allocator.free(result.stdout);
            if (result.diagnostics) |bytes| allocator.free(bytes);
        }
        try std.testing.expectEqual(case.error_expected, result.diagnostics != null);
        if (case.result) |expected| try std.testing.expectEqualStrings(expected, result.result.?) else try std.testing.expect(result.result == null);
    }
    try resetEnvironment(&state);
    const result = try compileAndRun(&state, "x");
    defer {
        if (result.result) |bytes| allocator.free(bytes);
        allocator.free(result.stdout);
        if (result.diagnostics) |bytes| allocator.free(bytes);
    }
    try std.testing.expect(result.diagnostics != null);
}
