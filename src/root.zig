pub const zmq = @import("zmq.zig");
pub const protocol = @import("protocol.zig");
pub const compiler_interface = @import("compiler_interface.zig");

test {
    _ = @import("zmq.zig");
    _ = @import("protocol.zig");
    _ = @import("compiler_interface.zig");
}
