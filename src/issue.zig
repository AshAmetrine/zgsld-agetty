const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("time.h");
    @cInclude("sys/utsname.h");
});

extern "c" fn ttyname_r(fd: std.posix.fd_t, buf: [*]u8, buflen: usize) c_int;

pub fn tryPrintIssue(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer) !void {
    const issue_data = try readFileAlloc(allocator, io, "/etc/issue", 64 * 1024);
    defer if (issue_data) |buf| allocator.free(buf);

    if (issue_data == null) return;

    // std.posix.uname returns void on freebsd
    var uts: c.struct_utsname = undefined;
    if (c.uname(&uts) != 0) return error.UnameFailed;

    var date_buf: [64]u8 = undefined;
    var time_buf: [32]u8 = undefined;
    var tty_buf: [32]u8 = undefined;
    const date = formatTime(&date_buf, "%a %b %e %Y") catch "";
    const time = formatTime(&time_buf, "%H:%M:%S") catch "";
    const tty = resolveTtyName(&tty_buf) catch "tty";

    const os_release = try readOsRelease(allocator, io);
    defer if (os_release) |buf| allocator.free(buf);

    const env = IssueEnv{
        .sysname = std.mem.sliceTo(&uts.sysname, 0),
        .nodename = std.mem.sliceTo(&uts.nodename, 0),
        .release = std.mem.sliceTo(&uts.release, 0),
        .version = std.mem.sliceTo(&uts.version, 0),
        .machine = std.mem.sliceTo(&uts.machine, 0),
        .tty = tty,
        .date = date,
        .time = time,
        .os_release = os_release,
    };

    try expandIssue(issue_data.?, writer, env);
}

const IssueEnv = struct {
    sysname: []const u8,
    nodename: []const u8,
    release: []const u8,
    version: []const u8,
    machine: []const u8,
    tty: []const u8,
    date: []const u8,
    time: []const u8,
    os_release: ?[]const u8,
};

fn expandIssue(input: []const u8, writer: *std.Io.Writer, env: IssueEnv) !void {
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '\\' or i + 1 >= input.len) {
            try writer.writeByte(input[i]);
            i += 1;
            continue;
        }

        const esc = input[i + 1];
        i += 2;

        switch (esc) {
            '\\' => try writer.writeByte('\\'),
            's' => try writer.writeAll(env.sysname),
            'n' => try writer.writeAll(env.nodename),
            'r' => try writer.writeAll(env.release),
            'v' => try writer.writeAll(env.version),
            'm' => try writer.writeAll(env.machine),
            'l' => try writer.writeAll(env.tty),
            'd' => try writer.writeAll(env.date),
            't' => try writer.writeAll(env.time),
            'o', 'O' => if (domainFromHost(env.nodename)) |domain| try writer.writeAll(domain),
            'e' => {
                if (parseBraced(input, &i)) |name| {
                    _ = try writeAnsiByName(writer, name);
                } else {
                    try writer.writeByte(0x1b);
                }
            },
            'S' => {
                if (parseBraced(input, &i)) |name| {
                    _ = try writeOsReleaseVar(writer, env, name);
                } else {
                    if (!(try writeOsReleaseVar(writer, env, "PRETTY_NAME"))) {
                        try writer.writeAll(env.sysname);
                    }
                }
            },
            else => {
                try writer.writeByte('\\');
                try writer.writeByte(esc);
            },
        }
    }
}

fn parseBraced(input: []const u8, index: *usize) ?[]const u8 {
    if (index.* >= input.len or input[index.*] != '{') return null;
    const start = index.* + 1;
    const end = std.mem.indexOfScalarPos(u8, input, start, '}') orelse return null;
    index.* = end + 1;
    return input[start..end];
}

fn domainFromHost(host: []const u8) ?[]const u8 {
    const dot = std.mem.indexOfScalar(u8, host, '.') orelse return null;
    if (dot + 1 >= host.len) return null;
    return host[dot + 1 ..];
}

fn writeAnsiByName(writer: *std.Io.Writer, name: []const u8) !bool {
    const maps = [_]struct { name: []const u8, seq: []const u8 }{
        .{ .name = "black", .seq = "\x1b[30m" },
        .{ .name = "red", .seq = "\x1b[31m" },
        .{ .name = "green", .seq = "\x1b[32m" },
        .{ .name = "yellow", .seq = "\x1b[33m" },
        .{ .name = "blue", .seq = "\x1b[34m" },
        .{ .name = "magenta", .seq = "\x1b[35m" },
        .{ .name = "cyan", .seq = "\x1b[36m" },
        .{ .name = "white", .seq = "\x1b[37m" },
        .{ .name = "bold", .seq = "\x1b[1m" },
        .{ .name = "blink", .seq = "\x1b[5m" },
        .{ .name = "reverse", .seq = "\x1b[7m" },
        .{ .name = "reset", .seq = "\x1b[0m" },
    };

    for (maps) |entry| {
        if (std.mem.eql(u8, name, entry.name)) {
            try writer.writeAll(entry.seq);
            return true;
        }
    }

    return false;
}

fn writeOsReleaseVar(writer: *std.Io.Writer, env: IssueEnv, name: []const u8) !bool {
    const data = env.os_release orelse return false;
    if (std.mem.eql(u8, name, "ANSI_COLOR")) {
        if (findOsReleaseValue(data, name)) |val| {
            if (val.len == 0) return false;
            try writer.writeAll("\x1b[");
            try writer.writeAll(val);
            try writer.writeAll("m");
            return true;
        }
        return false;
    }

    if (findOsReleaseValue(data, name)) |val| {
        try writer.writeAll(val);
        return true;
    }

    return false;
}

fn findOsReleaseValue(data: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const k = std.mem.trim(u8, trimmed[0..eq], " \t");
        if (!std.mem.eql(u8, k, key)) continue;
        var v = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
        if (v.len >= 2 and ((v[0] == '"' and v[v.len - 1] == '"') or (v[0] == '\'' and v[v.len - 1] == '\''))) {
            v = v[1 .. v.len - 1];
        }
        return v;
    }
    return null;
}

fn readOsRelease(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    if (try readFileAlloc(allocator, io, "/etc/os-release", 64 * 1024)) |buf| return buf;
    return try readFileAlloc(allocator, io, "/usr/lib/os-release", 64 * 1024);
}

fn readFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8, max_bytes: usize) !?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    var reader_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &reader_buf);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try reader.interface.readSliceShort(&chunk);
        if (n == 0) break;
        if (out.items.len + n > max_bytes) return error.FileTooBig;
        try out.appendSlice(allocator, chunk[0..n]);
        if (n < chunk.len) break;
    }

    return try out.toOwnedSlice(allocator);
}

const FormatTimeError = error{ TimeUnavailable, BufferTooSmall };

fn formatTime(buf: []u8, fmt: [:0]const u8) FormatTimeError![]const u8 {
    var t: c.time_t = c.time(null);
    var tm: c.struct_tm = undefined;
    if (c.localtime_r(&t, &tm) == null) return error.TimeUnavailable;
    const n = c.strftime(buf.ptr, buf.len, fmt, &tm);
    if (n == 0) return error.BufferTooSmall;
    return buf[0..n];
}

fn resolveTtyName(buf: []u8) ![]const u8 {
    const rc = ttyname_r(std.posix.STDIN_FILENO, buf.ptr, buf.len);
    if (rc != 0) return std.posix.unexpectedErrno(@enumFromInt(rc));

    const tty_path = std.mem.sliceTo(buf, 0);
    var offset: usize = 0;
    if (std.mem.startsWith(u8, tty_path, "/dev/")) {
        offset = "/dev/".len;
    }
    return buf[offset..tty_path.len :0];
}

test "expandIssue basics" {
    const env = IssueEnv{
        .sysname = "Linux",
        .nodename = "host.example",
        .release = "5.0",
        .version = "1",
        .machine = "x86_64",
        .tty = "tty1",
        .date = "2026-02-14",
        .time = "12:00:00",
        .os_release = "PRETTY_NAME=Test OS\nANSI_COLOR=31\n",
    };

    var out: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);

    const input = "X \\n \\s \\r \\m \\v \\l \\d \\t \\S \\S{ANSI_COLOR} \\e{red}Y\\e{reset} \\q \\\\";
    try expandIssue(input, &w, env);

    const esc = "\x1b";
    const expected = "X host.example Linux 5.0 x86_64 1 tty1 2026-02-14 12:00:00 Test OS " ++
        esc ++ "[31m " ++ esc ++ "[31mY" ++ esc ++ "[0m \\q \\";
    try std.testing.expectEqualStrings(expected, w.buffered());
}
