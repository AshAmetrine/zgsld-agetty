const std = @import("std");
const zgsld = @import("zgsld");
const zgipc = zgsld.ipc;
const clap = @import("clap");
const build_options = @import("build_options");
const issue = @import("issue.zig");

pub const Greeter = struct {
    allocator: std.mem.Allocator,
    ipc_conn: *zgipc.Ipc,
    termios: std.posix.termios,
    session_cmd: []const u8,

    ipc_rbuf: [zgipc.IPC_IO_BUF_SIZE]u8 = undefined,
    ipc_wbuf: [zgipc.IPC_IO_BUF_SIZE]u8 = undefined,
    ipc_reader: std.fs.File.Reader = undefined,
    ipc_writer: std.fs.File.Writer = undefined,

    stderr_buf: [1024]u8 = undefined,
    stdin_buf: [1024]u8 = undefined,
    stderr_writer: std.fs.File.Writer = undefined,
    stdin_reader: std.fs.File.Reader = undefined,

    pub fn init(allocator: std.mem.Allocator, ipc_conn: *zgipc.Ipc, session_cmd: []const u8) !Greeter {
        const termios = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var greeter: Greeter = .{
            .allocator = allocator,
            .ipc_conn = ipc_conn,
            .termios = termios,
            .session_cmd = session_cmd,
        };

        greeter.ipc_reader = ipc_conn.reader(&greeter.ipc_rbuf);
        greeter.ipc_writer = ipc_conn.writer(&greeter.ipc_wbuf);

        greeter.stderr_writer = std.fs.File.stderr().writer(&greeter.stderr_buf);
        greeter.stdin_reader = std.fs.File.stdin().reader(&greeter.stdin_buf);

        return greeter;
    }

    pub fn deinit(self: *Greeter) void {
        self.* = undefined;
    }

    pub fn run(self: *Greeter) !void {
        const stderr = &self.stderr_writer.interface;
        try issue.tryPrintIssue(self.allocator, stderr);

        const ipc_writer = &self.ipc_writer.interface;

        var authenticated = false;
        while (!authenticated) {
            authenticated = try self.tryAuth();
            if (!authenticated) try stderr.print("\nLogin incorrect\n", .{});
        }

        try self.ipc_conn.writeEvent(ipc_writer, &.{
            .start_session = .{
                .session_type = .Command,
                .command = .{ .session_cmd = self.session_cmd },
            },
        });

        try ipc_writer.flush();
    }

    fn tryAuth(self: *Greeter) !bool {
        const stderr = &self.stderr_writer.interface;
        const stdin = &self.stdin_reader.interface;
        const ipc_reader = &self.ipc_reader.interface;
        const ipc_writer = &self.ipc_writer.interface;

        try stderr.print("Username: ", .{});
        try stderr.flush();
        const username_raw = (try stdin.takeDelimiter('\n')) orelse "";
        const username_z = try self.allocator.dupeZ(u8, username_raw);
        defer self.allocator.free(username_z);

        const start_auth_event = zgipc.IpcEvent{
            .pam_start_auth = .{
                .user = username_z,
            },
        };

        try self.ipc_conn.writeEvent(ipc_writer, &start_auth_event);
        try ipc_writer.flush();

        defer {
            if (!self.termios.lflag.ECHO) {
                self.termios.lflag.ECHO = true;
                self.termios.lflag.ECHONL = true;
                std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.termios) catch {};
            }
        }

        var event_buf: [zgipc.GREETER_BUF_SIZE]u8 = undefined;
        while (true) {
            const event = try self.ipc_conn.readEvent(ipc_reader, event_buf[0..]);
            switch (event) {
                .pam_message => |info| {
                    const prefix = if (info.is_error) "error: " else "";
                    try stderr.print("{s}{s}\n", .{ prefix, info.message });
                    try stderr.flush();
                },
                .pam_request => |req| {
                    if (self.termios.lflag.ECHO != req.echo) {
                        self.termios.lflag.ECHO = req.echo;
                        self.termios.lflag.ECHONL = true;
                        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.termios);
                    }

                    try stderr.print("{s}", .{req.message});
                    try stderr.flush();
                    const user_input = try stdin.takeDelimiter('\n');
                    defer std.crypto.secureZero(u8, user_input.?);
                    const resp_event = zgipc.IpcEvent{ .pam_response = user_input.? };
                    try self.ipc_conn.writeEvent(ipc_writer, &resp_event);
                    try ipc_writer.flush();
                },
                .pam_auth_result => |result| return result.ok,
                else => unreachable,
            }
        }
    }
};
