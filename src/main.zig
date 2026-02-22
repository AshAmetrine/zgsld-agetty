const std = @import("std");
const build_options = @import("build_options");
const zgsld_mod = @import("zgsld");
const Zgsld = zgsld_mod.Zgsld;
const Greeter = @import("greeter.zig").Greeter;
const clap = @import("clap");

pub const std_options: std.Options = .{ .logFn = zgsld_mod.logFn };

const log = std.log.scoped(.zgsld_agetty);

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    if (!build_options.standalone and std.posix.getenv("ZGSLD_SOCK") == null) {
        const argv = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, argv);
        _ = try parseArgs(allocator, argv[1..]);

        log.err("This greeter should be run by zgsld", .{});
        return;
    }

    zgsld_mod.initZgsldLog();

    const zgsld = Zgsld.init(allocator, .{
        .run = run,
        .configure = configure,
    });

    try zgsld.run();
}

fn run(ctx: zgsld_mod.GreeterContext) !void {
    const argv = try std.process.argsAlloc(ctx.allocator);
    defer std.process.argsFree(ctx.allocator, argv);

    const config = try parseArgs(ctx.allocator, argv[1..]);

    var greeter = try Greeter.init(ctx.allocator, ctx.ipc, config.session_cmd);
    defer greeter.deinit();

    try greeter.run();
}

fn configure(ctx: zgsld_mod.ConfigureContext) !void {
    if (!build_options.standalone) unreachable;

    const argv = try std.process.argsAlloc(ctx.allocator);
    defer std.process.argsFree(ctx.allocator, argv);

    const parsed = try parseArgs(ctx.allocator, argv[1..]);
    if (parsed.greeter_user) |user| try ctx.cfg.setGreeterUser(user);
    if (parsed.service_name) |name| try ctx.cfg.setServiceName(name);
    if (parsed.vt) |vt| ctx.cfg.setVt(vt);
}

const ParsedArgs = if (build_options.standalone) struct {
    vt: ?u8 = null,
    greeter_user: ?[]const u8 = null,
    service_name: ?[]const u8 = null,
    session_cmd: []const u8,
} else struct {
    session_cmd: []const u8,
};

fn parseArgs(allocator: std.mem.Allocator, argv: []const [:0]const u8) !ParsedArgs {
    const param_str = if (build_options.standalone) blk: {
        break :blk 
        \\-h, --help                Shows all commands.
        \\-v, --version             Shows the version of zgsld-agetty.
        \\--vt <u8>                 Sets the VT number
        \\--greeter-user <str>      User that runs the greeter
        \\--service-name <str>      PAM service name used by the worker
        \\--cmd <str>               Session Command
        ;
    } else blk: {
        break :blk 
        \\-h, --help                Shows all commands.
        \\-v, --version             Shows the version of zgsld-agetty.
        \\--cmd <str>               Session Command
        ;
    };

    const params = comptime clap.parseParamsComptime(param_str);

    var diag = clap.Diagnostic{};
    var iter = clap.args.SliceIterator{ .args = argv };
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.reportToFile(.stderr(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try clap.helpToFile(.stderr(), clap.Help, &params, .{});
        std.process.exit(0);
    }

    if (res.args.version != 0) {
        var stderr_buf: [1024]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
        const stderr = &stderr_writer.interface;

        try stderr.writeAll("zgsld-agetty version " ++ build_options.version ++ "\n");
        try stderr.flush();
        std.process.exit(0);
    }

    if (build_options.standalone) {
        return .{
            .vt = res.args.vt,
            .greeter_user = res.args.@"greeter-user",
            .service_name = res.args.@"service-name",
            .session_cmd = res.args.cmd orelse return error.NullSessionCmd,
        };
    }

    return .{
        .session_cmd = res.args.cmd orelse return error.NullSessionCmd,
    };
}
