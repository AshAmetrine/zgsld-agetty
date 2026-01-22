const std = @import("std");
const zgipc = @import("zgipc");
const Greeter = @import("./greeter.zig").Greeter;

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var sock_fd: ?std.posix.fd_t = null;
    
    {
        const args = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args);

        for (args[1..],1..) |arg,i| {
            if (std.mem.eql(u8, arg, "--sock-fd")) {
                if (i >= args.len) return error.MissingSockFd;
                sock_fd = try std.fmt.parseInt(std.posix.fd_t, args[i+1], 10);
            }
        }
    }

    const fd = sock_fd orelse return error.MissingSockFd;
    var ipc_conn = zgipc.Ipc.initFromFd(fd);
    defer ipc_conn.deinit();

    var greeter = try Greeter.init(allocator, &ipc_conn);
    defer greeter.deinit();
    try greeter.run();
}
