const std = @import("std");
const main = @import("main.zig");
const zgsld = @import("zgsld");
const Ipc = zgsld.Ipc;
const issue = @import("issue.zig");

const IoHandles = struct {
    stdin: *std.Io.Reader,
    stderr: *std.Io.Writer,
    ipc_reader: *std.Io.Reader,
    ipc_writer: *std.Io.Writer,
};

pub const Greeter = struct {
    allocator: std.mem.Allocator,
    ipc_conn: *Ipc.Connection,
    session_cmd: []const u8,
    xdg_session_type: main.XdgSessionType,
    launch_session_type: Ipc.SessionType,
    termios: std.posix.termios,
    ipc_rbuf: [Ipc.event_buf_size]u8 = undefined,
    ipc_wbuf: [Ipc.event_buf_size]u8 = undefined,
    stderr_buf: [512]u8 = undefined,
    stdin_buf: [512]u8 = undefined,

    pub fn init(
        allocator: std.mem.Allocator,
        ipc_conn: *Ipc.Connection,
        session_cmd: []const u8,
        xdg_session_type: main.XdgSessionType,
    ) !Greeter {
        return .{
            .allocator = allocator,
            .ipc_conn = ipc_conn,
            .session_cmd = session_cmd,
            .xdg_session_type = xdg_session_type,
            .launch_session_type = switch (xdg_session_type) {
                .x11 => .x11,
                else => .command,
            },
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

        var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = try std.posix.gethostname(&hostname_buf);

        // Clear the terminal
        try io.stderr.writeAll("\x1b[2J\x1b[H");

        try issue.tryPrintIssue(self.allocator, io.stderr);

        while (!(try self.tryAuth(io, hostname))) {}

        try self.ipc_conn.writeEvent(io.ipc_writer, &.{
            .set_session_env = .{
                .key = "XDG_SESSION_TYPE",
                .value = @tagName(self.xdg_session_type),
            },
        });
        try self.ipc_conn.writeEvent(io.ipc_writer, &.{
            .start_session = .{
                .session_type = self.launch_session_type,
                .command = .{ .session_cmd = self.session_cmd },
            },
        });
        try io.ipc_writer.flush();
    }

    fn tryAuth(self: *Greeter, io: IoHandles, hostname: []const u8) !bool {
        try io.stderr.print("{s} login: ", .{hostname});
        try io.stderr.flush();
        const username_raw = (try io.stdin.takeDelimiter('\n')) orelse "";
        if (username_raw.len == 0) return false;
        const username_z = try self.allocator.dupeZ(u8, username_raw);
        defer self.allocator.free(username_z);

        try self.ipc_conn.writeEvent(io.ipc_writer, &.{
            .pam_start_auth = .{
                .user = username_z,
            },
        });
        try io.ipc_writer.flush();

        defer self.setEcho(true) catch {};

        var event_buf: [Ipc.event_buf_size]u8 = undefined;
        while (true) {
            const event = try self.ipc_conn.readEvent(io.ipc_reader, event_buf[0..]);
            switch (event) {
                .pam_message => |info| {
                    const prefix = if (info.is_error) "error: " else "";
                    try io.stderr.print("\n{s}{s}\n", .{ prefix, info.message });
                    try io.stderr.flush();
                },
                .pam_request => |req| {
                    try self.setEcho(req.echo);

                    try io.stderr.print("{s}", .{req.message});
                    try io.stderr.flush();
                    const user_input = try io.stdin.takeDelimiter('\n');
                    defer std.crypto.secureZero(u8, user_input.?);

                    const resp_event = Ipc.Event{ .pam_response = user_input.? };
                    try self.ipc_conn.writeEvent(io.ipc_writer, &resp_event);
                    try io.ipc_writer.flush();
                },
                .pam_auth_result => |result| {
                    if (!result.ok) {
                        try io.stderr.print("\nLogin incorrect\n", .{});
                    }
                    return result.ok;
                },
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
