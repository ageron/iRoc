const std = @import("std");

pub const c = @cImport({
    @cInclude("zmq.h");
    @cInclude("unistd.h");
});

/// ZeroMQ socket types supported by the kernel
pub const SocketType = enum(c_int) {
    router = c.ZMQ_ROUTER,
    dealer = c.ZMQ_DEALER,
    pubSock = c.ZMQ_PUB,
    sub = c.ZMQ_SUB,
    rep = c.ZMQ_REP,
};

/// Set of errors returned by ZeroMQ operations
pub const ZmqError = error{
    AccessDenied,
    AddressAlreadyInUse,
    AddressNotAvailable,
    ConnectionAborted,
    ConnectionRefused,
    ConnectionReset,
    HostUnreachable,
    InvalidArgument,
    MessageTooLong,
    NetworkDown,
    NetworkReset,
    NetworkUnreachable,
    NoBufferSpace,
    NoDevicesAvailable,
    NoMemory,
    NotSupported,
    NotSocket,
    OperationNotSupported,
    ProtocolNotSupported,
    ProtocolFailure,
    TimedOut,
    Interrupted,
    TryAgain,
    Unknown,
};

/// Translates standard C/ZMQ errno codes into Zig errors.
pub fn translateErrno(err: c_int) ZmqError {
    return switch (err) {
        c.EACCES => error.AccessDenied,
        c.EADDRINUSE => error.AddressAlreadyInUse,
        c.EADDRNOTAVAIL => error.AddressNotAvailable,
        c.ECONNABORTED => error.ConnectionAborted,
        c.ECONNREFUSED => error.ConnectionRefused,
        c.ECONNRESET => error.ConnectionReset,
        c.EHOSTUNREACH => error.HostUnreachable,
        c.EINVAL => error.InvalidArgument,
        c.EMSGSIZE => error.MessageTooLong,
        c.ENETDOWN => error.NetworkDown,
        c.ENETRESET => error.NetworkReset,
        c.ENETUNREACH => error.NetworkUnreachable,
        c.ENOBUFS => error.NoBufferSpace,
        c.ENODEV => error.NoDevicesAvailable,
        c.ENOMEM => error.NoMemory,
        c.ENOTSUP => error.NotSupported,
        c.ENOTSOCK => error.NotSocket,
        c.EPROTONOSUPPORT => error.ProtocolNotSupported,
        c.ETIMEDOUT => error.TimedOut,
        c.EINTR => error.Interrupted,
        c.EAGAIN => error.TryAgain,
        else => error.Unknown,
    };
}

/// A wrapper around a ZeroMQ context.
pub const Context = struct {
    handle: ?*anyopaque,

    /// Initializes a new ZeroMQ context.
    pub fn init() !Context {
        const handle = c.zmq_ctx_new() orelse return error.NoMemory;
        return Context{ .handle = handle };
    }

    /// Terminates the ZeroMQ context.
    pub fn deinit(self: *Context) void {
        if (self.handle) |h| {
            _ = c.zmq_ctx_term(h);
            self.handle = null;
        }
    }

    /// Creates a socket of the specified type in this context.
    pub fn createSocket(self: *Context, socketType: SocketType) !Socket {
        const socketHandle = c.zmq_socket(self.handle, @intFromEnum(socketType)) orelse {
            return translateErrno(c.zmq_errno());
        };
        return Socket{ .handle = socketHandle };
    }
};

/// A wrapper around a ZeroMQ message frame.
pub const Msg = struct {
    handle: c.zmq_msg_t,

    /// Initializes a new ZeroMQ message frame.
    pub fn init() !Msg {
        var self: Msg = undefined;
        if (c.zmq_msg_init(&self.handle) != 0) {
            return translateErrno(c.zmq_errno());
        }
        return self;
    }

    /// Closes and deallocates the message frame.
    pub fn deinit(self: *Msg) void {
        _ = c.zmq_msg_close(&self.handle);
    }

    /// Receives a message frame on the specified socket.
    pub fn recv(self: *Msg, socket: Socket, flags: c_int) !usize {
        const rc = c.zmq_msg_recv(&self.handle, socket.handle, flags);
        if (rc < 0) {
            return translateErrno(c.zmq_errno());
        }
        return @intCast(rc);
    }

    /// Accesses the raw data slice contained in the message frame.
    pub fn data(self: *const Msg) []const u8 {
        const rawPtr = c.zmq_msg_data(@constCast(&self.handle)) orelse return &[_]u8{};
        const ptr: [*]const u8 = @ptrCast(rawPtr);
        const len = c.zmq_msg_size(@constCast(&self.handle));
        return ptr[0..len];
    }
};

/// A wrapper around a ZeroMQ socket.
pub const Socket = struct {
    handle: ?*anyopaque,

    /// Closes the socket.
    pub fn deinit(self: *Socket) void {
        if (self.handle) |h| {
            _ = c.zmq_close(h);
            self.handle = null;
        }
    }

    /// Binds the socket to the specified endpoint.
    pub fn bind(self: Socket, endpoint: [*:0]const u8) !void {
        if (c.zmq_bind(self.handle, endpoint) != 0) {
            return translateErrno(c.zmq_errno());
        }
    }

    /// Connects the socket to the specified endpoint.
    pub fn connect(self: Socket, endpoint: [*:0]const u8) !void {
        if (c.zmq_connect(self.handle, endpoint) != 0) {
            return translateErrno(c.zmq_errno());
        }
    }

    /// Sends a single message buffer over the socket.
    pub fn send(self: Socket, buf: []const u8, flags: c_int) !usize {
        const rc = c.zmq_send(self.handle, buf.ptr, buf.len, flags);
        if (rc < 0) {
            return translateErrno(c.zmq_errno());
        }
        return @intCast(rc);
    }

    /// Retrieves a socket option.
    pub fn getOption(self: Socket, option: c_int, valuePtr: anytype) !void {
        const T = @TypeOf(valuePtr);
        const ptrInfo = switch (@typeInfo(T)) {
            .pointer => |info| info,
            else => @compileError("getOption expects a pointer argument"),
        };

        if (ptrInfo.size == .slice) {
            var size: usize = valuePtr.len;
            if (c.zmq_getsockopt(self.handle, option, valuePtr.ptr, &size) != 0) {
                return translateErrno(c.zmq_errno());
            }
        } else {
            var size: usize = @sizeOf(ptrInfo.child);
            if (c.zmq_getsockopt(self.handle, option, valuePtr, &size) != 0) {
                return translateErrno(c.zmq_errno());
            }
        }
    }

    /// Sets a socket option.
    pub fn setOption(self: Socket, option: c_int, value: anytype) !void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .pointer => |ptrInfo| {
                if (ptrInfo.size == .slice) {
                    if (c.zmq_setsockopt(self.handle, option, value.ptr, value.len) != 0) {
                        return translateErrno(c.zmq_errno());
                    }
                } else {
                    const size = @sizeOf(ptrInfo.child);
                    if (c.zmq_setsockopt(self.handle, option, value, size) != 0) {
                        return translateErrno(c.zmq_errno());
                    }
                }
            },
            else => {
                const size = @sizeOf(T);
                if (c.zmq_setsockopt(self.handle, option, &value, size) != 0) {
                    return translateErrno(c.zmq_errno());
                }
            },
        }
    }

    /// Checks if there are more message frames to receive.
    pub fn hasMore(self: Socket) !bool {
        var rcvmore: c_int = 0;
        try self.getOption(c.ZMQ_RCVMORE, &rcvmore);
        return rcvmore != 0;
    }

    /// Sends multiple message frames as a single multipart message.
    pub fn sendMultipart(self: Socket, parts: []const []const u8) !void {
        if (parts.len == 0) return;
        for (parts[0 .. parts.len - 1]) |part| {
            _ = try self.send(part, c.ZMQ_SNDMORE);
        }
        _ = try self.send(parts[parts.len - 1], 0);
    }

    /// Receives all frames of a multipart message.
    pub fn recvMultipart(self: Socket, allocator: std.mem.Allocator) ![][]u8 {
        var parts: std.ArrayList([]u8) = .empty;
        errdefer {
            for (parts.items) |part| {
                allocator.free(part);
            }
            parts.deinit(allocator);
        }

        while (true) {
            var msg = try Msg.init();
            defer msg.deinit();

            _ = try msg.recv(self, 0);
            const msgData = msg.data();
            const partCopy = try allocator.dupe(u8, msgData);
            try parts.append(allocator, partCopy);

            if (!try self.hasMore()) {
                break;
            }
        }

        return parts.toOwnedSlice(allocator);
    }
};

/// Connection configuration settings for the Jupyter sockets.
pub const ConnectionConfig = struct {
    transport: []const u8 = "tcp",
    ip: []const u8 = "127.0.0.1",
    shellPort: u16,
    stdinPort: u16,
    iopubPort: u16,
};

/// Combined set of ZeroMQ sockets for Jupyter communication.
pub const JupyterSockets = struct {
    context: Context,
    shell: Socket,
    stdin: Socket,
    iopub: Socket,

    /// Initializes and binds the Jupyter sockets.
    pub fn init(config: ConnectionConfig) !JupyterSockets {
        var context = try Context.init();
        errdefer context.deinit();

        var shell = try context.createSocket(.router);
        errdefer shell.deinit();

        var stdin = try context.createSocket(.dealer);
        errdefer stdin.deinit();

        var iopub = try context.createSocket(.pubSock);
        errdefer iopub.deinit();

        // Bind the sockets in order, using formatted strings
        var buf: [256]u8 = undefined;

        // Shell (ROUTER)
        const shellEndpoint = try std.fmt.bufPrintZ(&buf, "{s}://{s}:{d}", .{ config.transport, config.ip, config.shellPort });
        try shell.bind(shellEndpoint);

        // Stdin (DEALER)
        const stdinEndpoint = try std.fmt.bufPrintZ(&buf, "{s}://{s}:{d}", .{ config.transport, config.ip, config.stdinPort });
        try stdin.bind(stdinEndpoint);

        // IOPub (PUB)
        const iopubEndpoint = try std.fmt.bufPrintZ(&buf, "{s}://{s}:{d}", .{ config.transport, config.ip, config.iopubPort });
        try iopub.bind(iopubEndpoint);

        return JupyterSockets{
            .context = context,
            .shell = shell,
            .stdin = stdin,
            .iopub = iopub,
        };
    }

    /// Closes all active sockets and context.
    pub fn deinit(self: *JupyterSockets) void {
        self.iopub.deinit();
        self.stdin.deinit();
        self.shell.deinit();
        self.context.deinit();
    }
};

test "JupyterSockets binding and message passing" {
    const config = ConnectionConfig{
        .transport = "tcp",
        .ip = "127.0.0.1",
        .shellPort = 5555,
        .stdinPort = 5556,
        .iopubPort = 5557,
    };

    var sockets = try JupyterSockets.init(config);
    defer sockets.deinit();

    var clientContext = try Context.init();
    defer clientContext.deinit();

    var shellClient = try clientContext.createSocket(.dealer);
    defer shellClient.deinit();
    try shellClient.connect("tcp://127.0.0.1:5555");

    const testMsg = "hello shell";
    _ = try shellClient.send(testMsg, 0);

    const allocator = std.testing.allocator;

    const routerParts = try sockets.shell.recvMultipart(allocator);
    defer {
        for (routerParts) |p| allocator.free(p);
        allocator.free(routerParts);
    }

    try std.testing.expect(routerParts.len >= 2);
    try std.testing.expectEqualSlices(u8, testMsg, routerParts[routerParts.len - 1]);

    try sockets.shell.sendMultipart(routerParts);

    const clientParts = try shellClient.recvMultipart(allocator);
    defer {
        for (clientParts) |p| allocator.free(p);
        allocator.free(clientParts);
    }
    try std.testing.expectEqual(@as(usize, 1), clientParts.len);
    try std.testing.expectEqualSlices(u8, testMsg, clientParts[0]);

    var iopubClient = try clientContext.createSocket(.sub);
    defer iopubClient.deinit();
    try iopubClient.connect("tcp://127.0.0.1:5557");
    try iopubClient.setOption(c.ZMQ_SUBSCRIBE, @as([]const u8, ""));

    _ = c.usleep(50 * 1000);

    const pubMsg = "iopub status: ok";
    _ = try sockets.iopub.send(pubMsg, 0);

    const subParts = try iopubClient.recvMultipart(allocator);
    defer {
        for (subParts) |p| allocator.free(p);
        allocator.free(subParts);
    }
    try std.testing.expectEqual(@as(usize, 1), subParts.len);
    try std.testing.expectEqualSlices(u8, pubMsg, subParts[0]);
}
