const std = @import("std");
const zgsld = @import("zgsld");
const clap = @import("clap");
const build_options = @import("build_options");

pub const Greeter = struct {
    allocator: std.mem.Allocator,
    ipc_conn: *zgsld.Ipc,
    termios: std.posix.termios,

    ipc_rbuf: [zgsld.IPC_IO_BUF_SIZE]u8 = undefined,
    ipc_wbuf: [zgsld.IPC_IO_BUF_SIZE]u8 = undefined,
    ipc_reader: std.fs.File.Reader = undefined,
    ipc_writer: std.fs.File.Writer = undefined,

    stdout_buf: [1024]u8 = undefined,
    stdin_buf: [1024]u8 = undefined,
    stdout_writer: std.fs.File.Writer = undefined,
    stdin_reader: std.fs.File.Reader = undefined,

    pub fn init(allocator: std.mem.Allocator, ipc_conn: *zgsld.Ipc) !Greeter {
        const termios = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var greeter: Greeter = .{
            .allocator = allocator,
            .ipc_conn = ipc_conn,
            .termios = termios,
        };

        greeter.ipc_reader = ipc_conn.reader(&greeter.ipc_rbuf);
        greeter.ipc_writer = ipc_conn.writer(&greeter.ipc_wbuf);

        greeter.stdout_writer = std.fs.File.stdout().writer(&greeter.stdout_buf);
        greeter.stdin_reader = std.fs.File.stdin().reader(&greeter.stdin_buf);

        return greeter;
    }

    pub fn deinit(self: *Greeter) void {
        self.* = undefined;
    }

    pub fn run(self: *Greeter) !void {
        const ipc_writer = &self.ipc_writer.interface;
        // Greeter main loop
        var authenticated = false;
        while (!authenticated) {
            authenticated = try self.tryAuth();
            if (!authenticated) std.debug.print("Auth Failed\n", .{});
        }

        std.debug.print("\nAuth Succeeded\n", .{});

        try self.ipc_conn.writeEvent(ipc_writer, &.{
            .set_session_env = .{
                .key = "XDG_SESSION_TYPE",
                .value = "tty",
            },
        });

        try self.ipc_conn.writeEvent(ipc_writer, &.{
            .start_session = .{
                .session_type = .Command,
                .command = .{ .argv = "/bin/sh\x00" },
            },
        });

        try ipc_writer.flush();
    }

    fn tryAuth(self: *Greeter) !bool {
        const stdout = &self.stdout_writer.interface;
        const stdin = &self.stdin_reader.interface;
        const ipc_reader = &self.ipc_reader.interface;
        const ipc_writer = &self.ipc_writer.interface;

        try stdout.print("\nUsername: ", .{});
        try stdout.flush();
        const username_raw = (try stdin.takeDelimiter('\n')) orelse "";
        const username_z = try self.allocator.dupeZ(u8, username_raw);
        defer self.allocator.free(username_z);

        const start_auth_event = zgsld.IpcEvent{
            .pam_start_auth = .{
                .user = username_z,
            },
        };

        try self.ipc_conn.writeEvent(ipc_writer, &start_auth_event);
        try ipc_writer.flush();

        defer {
            if (!self.termios.lflag.ECHO) {
                self.termios.lflag.ECHO = true;
                std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.termios) catch {};
            }
        }

        var event_buf: [zgsld.GREETER_BUF_SIZE]u8 = undefined;
        while (true) {
            const event = try self.ipc_conn.readEvent(ipc_reader, event_buf[0..]);
            switch (event) {
                .pam_message => |info| {
                    const prefix = if (info.is_error) "error: " else "";
                    try stdout.print("{s}{s}\n", .{ prefix, info.message });
                    try stdout.flush();
                },
                .pam_request => |req| {
                    if (self.termios.lflag.ECHO != req.echo) {
                        self.termios.lflag.ECHO = req.echo;
                        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.termios);
                    }

                    try stdout.print("{s}", .{req.message});
                    try stdout.flush();
                    const user_input = try stdin.takeDelimiter('\n');
                    defer std.crypto.secureZero(u8, user_input.?);
                    const resp_event = zgsld.IpcEvent{ .pam_response = user_input.? };
                    try self.ipc_conn.writeEvent(ipc_writer, &resp_event);
                    try ipc_writer.flush();
                },
                .pam_auth_result => |result| return result.ok,
                else => unreachable,
            }
        }
    }
};
