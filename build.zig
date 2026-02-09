const std = @import("std");
const zgsld_build = @import("zgsld");

const basic_greeter_version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const standalone = b.option(bool, "standalone", "Build standalone greeter + session manager") orelse false;

    const zgsld = b.dependency("zgsld", .{ .target = target, .optimize = optimize });
    const clap = b.dependency("clap", .{ .target = target, .optimize = optimize });

    const version_str = try getVersionStr(b, "basic", basic_greeter_version);

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version_str);
    build_options.addOption(bool, "standalone", standalone);
    const build_options_mod = build_options.createModule();

    const basic_greeter = b.createModule(.{
        .root_source_file = b.path("src/greeter.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "clap", .module = clap.module("clap") },
        },
    });

    const exe = blk: {
        if (standalone) {
            break :blk zgsld_build.makeStandalone(b, .{
                .name = "basic-zgsl",
                .root_module = basic_greeter,
                .target = target,
                .optimize = optimize,
            });
        } else {
            break :blk b.addExecutable(.{
                .name = "basic-greeter",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/main.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "zgipc", .module = zgsld.module("zgipc") },
                        .{ .name = "build_options", .module = build_options_mod },
                        .{ .name = "clap", .module = clap.module("clap") },
                    },
                    .link_libc = true,
                }),
            });
        }
    };

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}

fn getVersionStr(b: *std.Build, name: []const u8, version: std.SemanticVersion) ![]const u8 {
    const version_str = b.fmt("{d}.{d}.{d}", .{ version.major, version.minor, version.patch });

    var status: u8 = undefined;
    const git_describe_raw = b.runAllowFail(&[_][]const u8{
        "git",
        "-C",
        b.build_root.path orelse ".",
        "describe",
        "--match",
        "*.*.*",
        "--tags",
    }, &status, .Ignore) catch {
        return version_str;
    };
    var git_describe = std.mem.trim(u8, git_describe_raw, " \n\r");
    git_describe = std.mem.trimLeft(u8, git_describe, "v");

    switch (std.mem.count(u8, git_describe, "-")) {
        0 => {
            if (!std.mem.eql(u8, version_str, git_describe)) {
                std.debug.print("{s} version '{s}' does not match git tag: '{s}'\n", .{ name, version_str, git_describe });
                std.process.exit(1);
            }
            return version_str;
        },
        2 => {
            // Untagged development build (e.g. 0.10.0-dev.2025+ecf0050a9).
            var it = std.mem.splitScalar(u8, git_describe, '-');
            const tagged_ancestor = std.mem.trimLeft(u8, it.first(), "v");
            const commit_height = it.next().?;
            const commit_id = it.next().?;

            const ancestor_ver = try std.SemanticVersion.parse(tagged_ancestor);
            if (version.order(ancestor_ver) != .gt) {
                std.debug.print("{s} version '{f}' must be greater than tagged ancestor '{f}'\n", .{ name, version, ancestor_ver });
                std.process.exit(1);
            }

            // Check that the commit hash is prefixed with a 'g' (a Git convention).
            if (commit_id.len < 1 or commit_id[0] != 'g') {
                std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
                return version_str;
            }

            // The version is reformatted in accordance with the https://semver.org specification.
            return b.fmt("{s}-dev.{s}+{s}", .{ version_str, commit_height, commit_id[1..] });
        },
        else => {
            std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
            return version_str;
        },
    }
}
