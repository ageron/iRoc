const std = @import("std");
const zmq = @import("zmq.zig");
const Socket = zmq.Socket;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// Jupyter message header format structure.
pub const Header = struct {
    msgId: []const u8,
    username: []const u8,
    session: []const u8,
    msgType: []const u8,
    version: []const u8,
    date: ?[]const u8 = null,
};

/// A union supporting both pre-serialized raw strings and JSON Value objects.
pub const JsonPayload = union(enum) {
    value: std.json.Value,
    raw: []const u8,
};

/// Represents a complete Jupyter protocol message.
pub const Message = struct {
    identities: [][]const u8 = &.{},
    signature: []const u8 = "",
    header: Header,
    parentHeader: JsonPayload = .{ .value = .null },
    metadata: JsonPayload = .{ .value = .null },
    content: JsonPayload = .{ .value = .null },
    buffers: [][]const u8 = &.{},
};

/// Contains the parsed Message structure and its allocated resources.
pub const ParsedMessage = struct {
    message: Message,
    arena: std.heap.ArenaAllocator,
    rawFrames: []const []const u8,
    allocator: std.mem.Allocator,

    /// Frees the allocated frames and the arena allocator.
    pub fn deinit(self: *ParsedMessage) void {
        for (self.rawFrames) |frame| {
            self.allocator.free(frame);
        }
        self.allocator.free(self.rawFrames);
        self.arena.deinit();
    }
};

/// Calculates the HMAC-SHA256 signature by hashing the concatenated serialized JSON strings.
pub fn calculateSignature(
    allocator: std.mem.Allocator,
    key: []const u8,
    buffers: []const []const u8,
) ![]const u8 {
    var hmac = HmacSha256.init(key);
    for (buffers) |buf| {
        hmac.update(buf);
    }
    var digest: [HmacSha256.mac_length]u8 = undefined;
    hmac.final(&digest);

    const hexArray = std.fmt.bytesToHex(digest, .lower);
    const hex = try allocator.alloc(u8, hexArray.len);
    @memcpy(hex, &hexArray);
    return hex;
}

/// Helper function to stringify a value to a dynamically allocated JSON string.
pub fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
}

/// Helper function to stringify a Header struct using standard Jupyter snake_case fields.
pub fn stringifyHeaderAlloc(allocator: std.mem.Allocator, header: Header) ![]u8 {
    var map: std.json.ObjectMap = .empty;
    defer map.deinit(allocator);
    try map.put(allocator, "msg_id", std.json.Value{ .string = header.msgId });
    try map.put(allocator, "username", std.json.Value{ .string = header.username });
    try map.put(allocator, "session", std.json.Value{ .string = header.session });
    try map.put(allocator, "msg_type", std.json.Value{ .string = header.msgType });
    try map.put(allocator, "version", std.json.Value{ .string = header.version });
    if (header.date) |date| {
        try map.put(allocator, "date", std.json.Value{ .string = date });
    }
    return try stringifyAlloc(allocator, std.json.Value{ .object = map });
}

/// Helper function to serialize any JsonPayload variant into a string.
pub fn stringifyPayloadAlloc(allocator: std.mem.Allocator, payload: JsonPayload) ![]const u8 {
    return switch (payload) {
        .raw => |raw| try allocator.dupe(u8, raw),
        .value => |val| try stringifyAlloc(allocator, val),
    };
}

/// Deserializes raw multipart frames into a ParsedMessage structure.
///
/// ZeroMQ ROUTER sockets prepend routing identity frames to incoming messages.
/// We scan for the "<IDS|MSG>" delimiter to split identities from the message payload.
pub fn deserialize(
    allocator: std.mem.Allocator,
    key: []const u8,
    frames: []const []const u8,
) !ParsedMessage {
    var delimIndex: ?usize = null;
    for (frames, 0..) |frame, i| {
        if (std.mem.eql(u8, frame, "<IDS|MSG>")) {
            delimIndex = i;
            break;
        }
    }
    const idx = delimIndex orelse return error.MissingDelimiter;

    if (frames.len < idx + 6) {
        return error.TruncatedMessage;
    }

    const receivedSig = frames[idx + 1];
    const headerJson = frames[idx + 2];
    const parentJson = frames[idx + 3];
    const metadataJson = frames[idx + 4];
    const contentJson = frames[idx + 5];

    if (key.len > 0) {
        const hashParts = [_][]const u8{ headerJson, parentJson, metadataJson, contentJson };
        const computedSig = try calculateSignature(allocator, key, &hashParts);
        defer allocator.free(computedSig);

        const sigLen = 64;
        if (receivedSig.len != sigLen or computedSig.len != sigLen) {
            return error.SignatureMismatch;
        }
        if (!std.crypto.timing_safe.eql([sigLen]u8, receivedSig[0..sigLen].*, computedSig[0..sigLen].*)) {
            return error.SignatureMismatch;
        }
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arenaAllocator = arena.allocator();

    var identities = try arenaAllocator.alloc([]const u8, idx);
    for (frames[0..idx], 0..) |f, i| {
        identities[i] = try arenaAllocator.dupe(u8, f);
    }

    const parsedHeader = try std.json.parseFromSlice(std.json.Value, arenaAllocator, headerJson, .{ .ignore_unknown_fields = true });
    const parsedParent = try std.json.parseFromSlice(std.json.Value, arenaAllocator, parentJson, .{ .ignore_unknown_fields = true });
    const parsedMetadata = try std.json.parseFromSlice(std.json.Value, arenaAllocator, metadataJson, .{ .ignore_unknown_fields = true });
    const parsedContent = try std.json.parseFromSlice(std.json.Value, arenaAllocator, contentJson, .{ .ignore_unknown_fields = true });

    const headerObj = parsedHeader.value.object;
    const header = Header{
        .msgId = try arenaAllocator.dupe(u8, headerObj.get("msg_id").?.string),
        .username = try arenaAllocator.dupe(u8, headerObj.get("username").?.string),
        .session = try arenaAllocator.dupe(u8, headerObj.get("session").?.string),
        .msgType = try arenaAllocator.dupe(u8, headerObj.get("msg_type").?.string),
        .version = try arenaAllocator.dupe(u8, headerObj.get("version").?.string),
        .date = if (headerObj.get("date")) |d| try arenaAllocator.dupe(u8, d.string) else null,
    };

    const numBuffers = frames.len - (idx + 6);
    var buffers = try arenaAllocator.alloc([]const u8, numBuffers);
    for (frames[idx + 6 ..], 0..) |f, i| {
        buffers[i] = try arenaAllocator.dupe(u8, f);
    }

    return ParsedMessage{
        .message = Message{
            .identities = identities,
            .signature = try arenaAllocator.dupe(u8, receivedSig),
            .header = header,
            .parentHeader = .{ .value = parsedParent.value },
            .metadata = .{ .value = parsedMetadata.value },
            .content = .{ .value = parsedContent.value },
            .buffers = buffers,
        },
        .arena = arena,
        .rawFrames = frames,
        .allocator = allocator,
    };
}

/// Serializes a Message into standard Jupyter protocol frames.
pub fn serialize(
    allocator: std.mem.Allocator,
    key: []const u8,
    msg: Message,
) ![][]const u8 {
    const headerJson = try stringifyHeaderAlloc(allocator, msg.header);
    errdefer allocator.free(headerJson);

    const parentJson = try stringifyPayloadAlloc(allocator, msg.parentHeader);
    errdefer allocator.free(parentJson);

    const metadataJson = try stringifyPayloadAlloc(allocator, msg.metadata);
    errdefer allocator.free(metadataJson);

    const contentJson = try stringifyPayloadAlloc(allocator, msg.content);
    errdefer allocator.free(contentJson);

    const hashParts = [_][]const u8{ headerJson, parentJson, metadataJson, contentJson };
    const signature = try calculateSignature(allocator, key, &hashParts);
    errdefer allocator.free(signature);

    const numFrames = msg.identities.len + 1 + 1 + 4 + msg.buffers.len;
    var frames = try allocator.alloc([]const u8, numFrames);
    errdefer allocator.free(frames);

    var idx: usize = 0;
    for (msg.identities) |identity| {
        frames[idx] = try allocator.dupe(u8, identity);
        idx += 1;
    }

    frames[idx] = try allocator.dupe(u8, "<IDS|MSG>");
    idx += 1;

    frames[idx] = signature;
    idx += 1;

    frames[idx] = headerJson;
    idx += 1;

    frames[idx] = parentJson;
    idx += 1;

    frames[idx] = metadataJson;
    idx += 1;

    frames[idx] = contentJson;
    idx += 1;

    for (msg.buffers) |buf| {
        frames[idx] = try allocator.dupe(u8, buf);
        idx += 1;
    }

    return frames;
}

/// Serializes and transmits a Message over the ZeroMQ socket.
///
/// Under ZeroMQ's ROUTER protocol, any routing identities must be transmitted
/// first using ZMQ_SNDMORE flags, followed by the delimiter "<IDS|MSG>", the signature,
/// and the message payloads.
pub fn sendMessage(socket: Socket, allocator: std.mem.Allocator, key: []const u8, msg: Message, is_iopub: bool) !void {
    const headerJson = try stringifyHeaderAlloc(allocator, msg.header);
    defer allocator.free(headerJson);

    const parentJson = try stringifyPayloadAlloc(allocator, msg.parentHeader);
    defer allocator.free(parentJson);

    const metadataJson = try stringifyPayloadAlloc(allocator, msg.metadata);
    defer allocator.free(metadataJson);

    const contentJson = try stringifyPayloadAlloc(allocator, msg.content);
    defer allocator.free(contentJson);

    const hashParts = [_][]const u8{ headerJson, parentJson, metadataJson, contentJson };
    const signature = try calculateSignature(allocator, key, &hashParts);
    defer allocator.free(signature);

    if (is_iopub) {
        _ = try socket.send(msg.header.msgType, zmq.c.ZMQ_SNDMORE);
    } else {
        for (msg.identities) |identity| {
            _ = try socket.send(identity, zmq.c.ZMQ_SNDMORE);
        }
    }
    _ = try socket.send("<IDS|MSG>", zmq.c.ZMQ_SNDMORE);

    _ = try socket.send(signature, zmq.c.ZMQ_SNDMORE);
    _ = try socket.send(headerJson, zmq.c.ZMQ_SNDMORE);
    _ = try socket.send(parentJson, zmq.c.ZMQ_SNDMORE);
    _ = try socket.send(metadataJson, zmq.c.ZMQ_SNDMORE);

    if (msg.buffers.len > 0) {
        _ = try socket.send(contentJson, zmq.c.ZMQ_SNDMORE);
        for (msg.buffers[0 .. msg.buffers.len - 1]) |buf| {
            _ = try socket.send(buf, zmq.c.ZMQ_SNDMORE);
        }
        _ = try socket.send(msg.buffers[msg.buffers.len - 1], 0);
    } else {
        _ = try socket.send(contentJson, 0);
    }
}

/// Receives and deserializes a Jupyter message from a ZeroMQ socket.
pub fn recvMessage(socket: Socket, allocator: std.mem.Allocator, key: []const u8) !ParsedMessage {
    const rawFrames = socket.recvMultipart(allocator) catch |err| {
        std.log.err("recvMessage failed: {}", .{err});
        return err;
    };
    var allocatedCount: usize = rawFrames.len;
    errdefer {
        for (rawFrames[0..allocatedCount]) |f| allocator.free(f);
        allocator.free(rawFrames);
    }

    const frames = allocator.alloc([]const u8, rawFrames.len) catch |err| {
        std.log.err("recvMessage failed: {}", .{err});
        return err;
    };
    var framesAllocated: usize = 0;
    errdefer {
        for (frames[0..framesAllocated]) |f| allocator.free(f);
        allocator.free(frames);
    }

    for (rawFrames) |f| {
        frames[framesAllocated] = f;
        framesAllocated += 1;
    }
    allocatedCount = 0;

    const parsed = deserialize(allocator, key, frames) catch |err| {
        std.log.err("recvMessage failed: {}", .{err});
        return err;
    };

    allocator.free(rawFrames);
    return parsed;
}

test "serialize and deserialize message" {
    const allocator = std.testing.allocator;
    const key = "secret-key";

    var metadataMap: std.json.ObjectMap = .empty;
    defer metadataMap.deinit(allocator);

    var contentMap: std.json.ObjectMap = .empty;
    defer contentMap.deinit(allocator);
    try contentMap.put(allocator, "code", std.json.Value{ .string = "print('hello')" });

    const msg = Message{
        .identities = @constCast(&[_][]const u8{"client-uuid"}),
        .header = Header{
            .msgId = "msg-123",
            .username = "username-123",
            .session = "session-123",
            .msgType = "execute_request",
            .version = "5.3",
        },
        .parentHeader = .{ .value = .null },
        .metadata = .{ .value = std.json.Value{ .object = metadataMap } },
        .content = .{ .value = std.json.Value{ .object = contentMap } },
    };

    const frames = try serialize(allocator, key, msg);
    errdefer {
        for (frames) |f| allocator.free(f);
        allocator.free(frames);
    }

    var parsed = try deserialize(allocator, key, frames);
    defer parsed.deinit();

    try std.testing.expectEqualSlices(u8, "client-uuid", parsed.message.identities[0]);
    try std.testing.expectEqualSlices(u8, "msg-123", parsed.message.header.msgId);
    try std.testing.expectEqualSlices(u8, "execute_request", parsed.message.header.msgType);
    try std.testing.expect(parsed.message.parentHeader.value == .null);

    const parsedContent = parsed.message.content.value.object;
    try std.testing.expectEqualSlices(u8, "print('hello')", parsedContent.get("code").?.string);
}

test "Jupyter message transmission over ZMQ" {
    const config = zmq.ConnectionConfig{
        .transport = "tcp",
        .ip = "127.0.0.1",
        .shellPort = 5558,
        .stdinPort = 5559,
        .iopubPort = 5560,
    };

    var sockets = try zmq.JupyterSockets.init(config);
    defer sockets.deinit();

    var clientContext = try zmq.Context.init();
    defer clientContext.deinit();

    var shellClient = try clientContext.createSocket(.dealer);
    defer shellClient.deinit();
    try shellClient.connect("tcp://127.0.0.1:5558");

    const key = "secret-key";
    const allocator = std.testing.allocator;

    const clientMsg = Message{
        .identities = &.{},
        .header = Header{
            .msgId = "msg-999",
            .username = "user",
            .session = "session-999",
            .msgType = "execute_request",
            .version = "5.3",
        },
        .parentHeader = .{ .value = .null },
        .metadata = .{ .value = .null },
        .content = .{ .value = .null },
    };

    try sendMessage(shellClient, allocator, key, clientMsg, false);

    var parsed = try recvMessage(sockets.shell, allocator, key);
    defer parsed.deinit();

    try std.testing.expectEqualSlices(u8, "msg-999", parsed.message.header.msgId);
    try std.testing.expectEqualSlices(u8, "execute_request", parsed.message.header.msgType);
}
