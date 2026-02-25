const std = @import("std");
const zgsld = @import("zgsld");
const zgipc = zgsld.ipc;
const issue = @import("issue.zig");

const IoHandles = struct {
    stdin: *std.Io.Reader,
    stderr: *std.Io.Writer,
    ipc_reader: *std.Io.Reader,
    ipc_writer: *std.Io.Writer,
};

pub const Greeter = struct {
    allocator: std.mem.Allocator,
    ipc_conn: *zgipc.Ipc,
    session_cmd: []const u8,
    termios: std.posix.termios,
    ipc_rbuf: [zgipc.IPC_IO_BUF_SIZE]u8 = undefined,
    ipc_wbuf: [zgipc.IPC_IO_BUF_SIZE]u8 = undefined,
    stderr_buf: [512]u8 = undefined,
    stdin_buf: [512]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, ipc_conn: *zgipc.Ipc, session_cmd: []const u8) !Greeter {
        return .{
            .allocator = allocator,
            .ipc_conn = ipc_conn,
            .session_cmd = session_cmd,
            .termios = try std.posix.tcgetattr(std.posix.STDIN_FILENO),
        };
    }

    pub fn run(self: *Greeter) !void {
        var ipc_reader = self.ipc_conn.reader(&self.ipc_rbuf);
        var ipc_writer = self.ipc_conn.writer(&self.ipc_wbuf);
        var stderr_writer = std.fs.File.stderr().writer(&self.stderr_buf);
        var stdin_reader = std.fs.File.stdin().reader(&self.stdin_buf);
        const io: IoHandles = .{
            .stdin = &stdin_reader.interface,
            .stderr = &stderr_writer.interface,
            .ipc_reader = &ipc_reader.interface,
            .ipc_writer = &ipc_writer.interface,
        };

        try issue.tryPrintIssue(self.allocator, io.stderr);

        while (!(try self.tryAuth(io))) {
            try io.stderr.print("\nLogin incorrect\n", .{});
        }

        try self.ipc_conn.writeEvent(io.ipc_writer, &.{
            .start_session = .{
                .session_type = .Command,
                .command = .{ .session_cmd = self.session_cmd },
            },
        });
        try io.ipc_writer.flush();
    }

    fn tryAuth(self: *Greeter, io: IoHandles) !bool {
        try io.stderr.print("Username: ", .{});
        try io.stderr.flush();
        const username_raw = (try io.stdin.takeDelimiter('\n')) orelse "";
        const username_z = try self.allocator.dupeZ(u8, username_raw);
        defer self.allocator.free(username_z);

        try self.ipc_conn.writeEvent(io.ipc_writer, &.{
            .pam_start_auth = .{
                .user = username_z,
            },
        });
        try io.ipc_writer.flush();

        defer self.setEcho(true) catch {};

        var event_buf: [zgipc.GREETER_BUF_SIZE]u8 = undefined;
        while (true) {
            const event = try self.ipc_conn.readEvent(io.ipc_reader, event_buf[0..]);
            switch (event) {
                .pam_message => |info| {
                    const prefix = if (info.is_error) "error: " else "";
                    try io.stderr.print("{s}{s}\n", .{ prefix, info.message });
                    try io.stderr.flush();
                },
                .pam_request => |req| {
                    try self.setEcho(req.echo);

                    try io.stderr.print("{s}", .{req.message});
                    try io.stderr.flush();
                    const user_input = try io.stdin.takeDelimiter('\n');
                    defer std.crypto.secureZero(u8, user_input.?);

                    const resp_event = zgipc.IpcEvent{ .pam_response = user_input.? };
                    try self.ipc_conn.writeEvent(io.ipc_writer, &resp_event);
                    try io.ipc_writer.flush();
                },
                .pam_auth_result => |result| return result.ok,
                else => unreachable,
            }
        }
    }

    fn setEcho(self: *Greeter, echo: bool) !void {
        if (self.termios.lflag.ECHO == echo) return;
        self.termios.lflag.ECHO = echo;
        self.termios.lflag.ECHONL = true;
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.termios);
    }
};
