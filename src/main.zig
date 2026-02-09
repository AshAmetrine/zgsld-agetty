const std = @import("std");
const zgsld = @import("zgipc");
const greeter_api = @import("./greeter.zig").greeter_api;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var sock_fd: ?std.posix.fd_t = null;
    if (std.posix.getenv("ZGSLD_SOCK")) |sock| {
        sock_fd = try std.fmt.parseInt(std.posix.fd_t, sock, 10);
    }

    const fd = sock_fd orelse return error.MissingSockFd;
    var ipc_conn = zgsld.Ipc.initFromFd(fd);
    defer ipc_conn.deinit();

    try greeter_api.run(.{
        .allocator = allocator,
        .ipc = &ipc_conn,
    });

    std.debug.print("Greeter Exiting...\n", .{});
}
