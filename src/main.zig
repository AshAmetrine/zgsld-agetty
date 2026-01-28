const std = @import("std");
const zgipc = @import("zgipc");
const Greeter = @import("./greeter.zig").Greeter;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var sock_fd: ?std.posix.fd_t = null;
    if (std.posix.getenv("ZGSLD_SOCK")) |sock| {
        sock_fd = try std.fmt.parseInt(std.posix.fd_t, sock, 10);
    }
    
    const fd = sock_fd orelse return error.MissingSockFd;
    var ipc_conn = zgipc.Ipc.initFromFd(fd);
    defer ipc_conn.deinit();

    var greeter = try Greeter.init(allocator, &ipc_conn);
    defer greeter.deinit();
    try greeter.run();

    std.debug.print("Greeter Exiting...\n",.{});
}
