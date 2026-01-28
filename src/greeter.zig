const std = @import("std");
const zgipc = @import("zgipc");
const clap = @import("clap");
const build_options = @import("build_options");


pub const Greeter = struct {
    allocator: std.mem.Allocator,
    ipc_conn: *zgipc.Ipc,
    termios: std.posix.termios,

    stderr_buf: [1024]u8 = undefined,
    stdin_buf: [1024]u8 = undefined,
    stderr_writer: std.fs.File.Writer = undefined,
    stdin_reader: std.fs.File.Reader = undefined,

    pub fn init(allocator: std.mem.Allocator, ipc_conn: *zgipc.Ipc) !Greeter {
        const termios = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var greeter: Greeter = .{
            .allocator = allocator,
            .ipc_conn = ipc_conn,
            .termios = termios,
        };

        greeter.stderr_writer = std.fs.File.stderr().writer(&greeter.stderr_buf);
        greeter.stdin_reader = std.fs.File.stdin().reader(&greeter.stdin_buf);

        return greeter;
    }

    pub fn deinit(self: *Greeter) void {
        _ = self;
    }

    pub fn serviceName() []const u8 {
        return "login";
    }

    pub fn handleInitialArgs(allocator: std.mem.Allocator) !void {
        var stderr_buf: [1024]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
        const stderr = &stderr_writer.interface;

        const paramStr =
            \\-h, --help                Shows all commands.
            \\-v, --version             Shows the version of basic-greeter.
        ;

        const params = comptime clap.parseParamsComptime(paramStr);

        var diag = clap.Diagnostic{};
        var res = clap.parse(clap.Help, &params, clap.parsers.default, .{ .diagnostic = &diag, .allocator = allocator }) catch |err| {
            diag.reportToFile(.stderr(), err) catch {};
            return err;
        };
        defer res.deinit();


        if (res.args.help != 0) {
            try clap.helpToFile(.stderr(), clap.Help, &params, .{});
            std.process.exit(0);
        }
        if (res.args.version != 0) {
            try stderr.writeAll("Basic Greeter version " ++ build_options.version ++ "\n");
            try stderr.flush();
            std.process.exit(0);
        }

        // Other args can be verified to be correct for when the greeter runs
    }

    pub fn run(self: *Greeter) !void {
        // Greeter main loop
        var authenticated = false;
        while (!authenticated) {
            authenticated = try self.tryAuth();
            if (!authenticated) std.debug.print("Auth Failed\n",.{});
        }

        std.debug.print("\nAuth Succeeded\n",.{});

        std.debug.print("Sending Session Env Vars\n",.{});

        try self.ipc_conn.writeEvent(&.{
            .set_session_env = .{ 
                .key = "XDG_SESSION_TYPE", 
                .value = "tty", 
            },
        });

        std.debug.print("Sending start_session event\n",.{});

        try self.ipc_conn.writeEvent(&.{ 
            .start_session = .{ 
                .Command = .{ .argv = "/bin/sh\x00" }
            }
        });

        try self.ipc_conn.flush();
        std.debug.print("Sent start_session Event\n",.{});
    }

    fn tryAuth(self: *Greeter) !bool {
        const stderr = &self.stderr_writer.interface;
        const stdin = &self.stdin_reader.interface;

        try stderr.print("\nUsername: ",.{});
        try stderr.flush();
        const username_raw = (try stdin.takeDelimiter('\n')) orelse "";
        const username_z = try self.allocator.dupeZ(u8, username_raw);
        defer self.allocator.free(username_z);

        const start_auth_event = zgipc.IpcEvent{
            .pam_start_auth = .{
                .user = username_z,
            },
        };

        try self.ipc_conn.writeEvent(&start_auth_event);
        try self.ipc_conn.flush();

        defer {
            if (!self.termios.lflag.ECHO) {
                self.termios.lflag.ECHO = true;
                std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.termios) catch {};
            }
        }

        var event_buf: [zgipc.GREETER_BUF_SIZE]u8 = undefined;
        while (true) {
            const event = try self.ipc_conn.readEvent(event_buf[0..]);
            switch (event) {
                .pam_message => |info| {
                    const prefix = if (info.is_error) "error: " else "";
                    try stderr.print("{s}{s}\n", .{ prefix, info.message });
                    try stderr.flush();
                },
                .pam_request => |req| {
                    if (self.termios.lflag.ECHO != req.echo) {
                        self.termios.lflag.ECHO = req.echo;
                        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.termios);
                    }

                    try stderr.print("{s}", .{req.message});
                    try stderr.flush();
                    const user_input = try stdin.takeDelimiter('\n');
                    defer std.crypto.secureZero(u8, user_input.?);
                    const resp_event = zgipc.IpcEvent{ .pam_response = user_input.? };
                    try self.ipc_conn.writeEvent(&resp_event);
                    try self.ipc_conn.flush();
                },
                .pam_auth_result => |result| return result.ok,
                else => unreachable,
            }
        }
    }
};
