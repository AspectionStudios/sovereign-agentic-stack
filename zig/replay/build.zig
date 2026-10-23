const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const z2d_options_mod = b.createModule(.{
        .root_source_file = b.path("z2d_options.zig"),
        .target = target,
        .optimize = optimize,
    });

    const z2d_mod = b.createModule(.{
        .root_source_file = b.path("z2d/src/z2d.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "z2d_options", .module = z2d_options_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "replay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("replay.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "z2d", .module = z2d_mod },
            },
        }),
    });
    b.installArtifact(exe);
}
