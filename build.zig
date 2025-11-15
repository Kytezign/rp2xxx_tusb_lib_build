const std = @import("std");
const builtin = @import("builtin");
const microzig = @import("microzig");

const MicroBuild = microzig.MicroBuild(.{
    .rp2xxx = true,
});

// VIDPID of the picoprobe currently.
const VID = 0x2e8a;
const PID = 0xc;
const MAGICREBOOTCODE: u8 = 0xAB; // reboot code

/// Make these global so we can do force reboot of device -> load FW (load_start) -> done load FW (load_end) -> start monitoring
/// TODO: Refactor this dependency stuff
var load_start: *std.Build.Step = undefined;
var load_end: *std.Build.Step = undefined;

pub fn build(b: *std.Build) !void {
    const name = "zig_deploy";
    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;
    const target = mb.ports.rp2xxx.boards.raspberrypi.pico;

    const firmware = mb.add_firmware(.{
        .name = name,
        .target = target,
        .optimize = .ReleaseSafe,
        .root_source_file = b.path("src/tusb_cdc.zig"),
    });

    // Adding tinyusb required files
    const csources = [_]std.Build.LazyPath{b.path("src/tusb_descriptors.c")};
    const includes = [_]std.Build.LazyPath{b.path("src")};

    MicroBuild.addTinyUsbLib(b, firmware, &csources, &includes);

    // Setting options for the device
    // using this magic command, make sure both the host exe and the device share the same code.
    const options = b.addOptions();
    options.addOption(@TypeOf(MAGICREBOOTCODE), "rebootcmd", MAGICREBOOTCODE);
    firmware.app_mod.addOptions("uconfig", options);

    mb.install_firmware(firmware, .{});
    mb.install_firmware(firmware, .{ .format = .elf });

    // Add disassemble step
    try addDisassembleStep(b, firmware.get_emitted_elf());
    // load step (requires device in boot mode currently)
    const uf2_path = firmware.get_emitted_bin(firmware.target.preferred_binary_format);
    try addLoadStep(b, uf2_path);
    // run/test step:
    addSerialCtrl(b);
}

/// Disassembles the produced elf file.  Requires system tool arm-none-eabi-objdump to be available
fn addDisassembleStep(b: *std.Build, elf_path: std.Build.LazyPath) !void {
    const disassemble_argv = [_][]const u8{ "arm-none-eabi-objdump", "-D" };
    const dis_cmd = b.addSystemCommand(&disassemble_argv);
    dis_cmd.addFileArg(elf_path);
    dis_cmd.has_side_effects = true;
    const output = dis_cmd.captureStdOut();
    const dis = b.step("dis", "disassemble the elf file");
    dis.dependOn(b.getInstallStep());
    // TODO: make the name dynamic... (below doesn't work)
    // const new_path = try std.fmt.allocPrint(b.allocator, "{s}.dis", .{elf_path.basename(b, &dis_cmd.step)});
    dis.dependOn(&b.addInstallFileWithDir(output, .prefix, "output.dis").step);
    dis.dependOn(&dis_cmd.step);
}

/// Adds a "load" step to the build which will call picotool.
/// If picotool is not in the path, it will try to pull it from dependencies (pre-built from RP group)
/// To load the input UF2 the RP2040 must be in boot mode
/// After load it restarts the board
/// TODO: do a force load using vendor interface eventually (once we can get RP2040 USB setup that way)
pub fn addLoadStep(b: *std.Build, uf2_path: std.Build.LazyPath) !void {
    load_end = b.step("load", "Loads the uf2 with picotool");
    load_start = b.step("possibly_get_picotool", "must be run before using to ensure picotool is available.");
    // Find picotool
    // Check for picotool in system path
    const picotool_prog = b.findProgram(&.{"picotool"}, &.{}) catch blk: {
        // If not in path we'll try to pull it in from the lazy dep defined in zig.zon.
        if (b.lazyDependency("linux_picotool", .{})) |picotool_dep| {
            std.debug.assert(builtin.os.tag == .linux); // TODO: only pulling linux currently should not be hard to add others
            const install_picotool = b.addInstallBinFile(picotool_dep.path("picotool/picotool"), "picotool");
            b.getInstallStep().dependOn(&install_picotool.step);
            load_start.dependOn(&install_picotool.step);
            break :blk b.getInstallPath(install_picotool.dir, install_picotool.dest_rel_path);
        } else {
            // I guess if it's not fetched (lazy Dep and there is no system level picotool we just return)
            return;
        }
    };
    const load_uf2_argv = [_][]const u8{ picotool_prog, "load" };
    const load_uf2_cmd = b.addSystemCommand(&load_uf2_argv);
    load_uf2_cmd.addFileArg(uf2_path);
    load_uf2_cmd.setName("picotool: load into device");
    load_uf2_cmd.has_side_effects = true;
    const restart = [_][]const u8{ picotool_prog, "reboot" };
    const restart_cmd = b.addSystemCommand(&restart);
    restart_cmd.setName("picotool: reboot device");
    restart_cmd.has_side_effects = true;

    // top level install step -> install picotool (if needed) -> picotool load -> picotool reboot -> load step
    // the load_start & load_end steps are also referenced in the addSerialCtrl (related to the runtest step)
    load_uf2_cmd.step.dependOn(b.getInstallStep());
    load_uf2_cmd.step.dependOn(load_start);
    restart_cmd.step.dependOn(&load_uf2_cmd.step);
    load_end.dependOn(&restart_cmd.step);
    return;
}

/// Creates runtest step and compiles the serialctrl.zig program.
/// Adds a step to request a reboot and log output.
/// VID/PID search criteria is hardcoded here since this is only intended as a build tool.
fn addSerialCtrl(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build an executable from the serialctrl.zig
    const exe = b.addExecutable(.{
        .name = "serialhelp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("serialctrl.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add config options based on device & HW setup
    const options = b.addOptions();
    options.addOption(u16, "vid", VID);
    options.addOption(u16, "pid", PID);
    options.addOption(@TypeOf(MAGICREBOOTCODE), "rebootcmd", MAGICREBOOTCODE);
    exe.root_module.addOptions("config", options);

    if (b.lazyDependency("serial", .{})) |serial_dep| {
        exe.root_module.addImport("serial", serial_dep.module("serial"));
    } else {
        return;
    }
    // Add a build step for installing the executable
    b.installArtifact(exe);

    // Create force reboot step - calling the executable with the argument "reboot"
    const reboot_cmd = b.addRunArtifact(exe);
    reboot_cmd.addArg("reboot");
    reboot_cmd.has_side_effects = true;
    reboot_cmd.step.name = "Force Reboot with Serial";

    // Create monitoring only step - calling executable with no arguments
    const monitor_cmd = b.addRunArtifact(exe);
    monitor_cmd.has_side_effects = true;
    monitor_cmd.step.name = "Start Monitoring";

    // Run test step zig build runtest.
    const run_test = b.step("runtest", "Monitors serial output");

    // Make sure reboot is called before the load_start step and monitoring is called after load_end step.
    reboot_cmd.step.dependOn(b.getInstallStep());
    load_start.dependOn(&reboot_cmd.step);
    monitor_cmd.step.dependOn(load_end);
    run_test.dependOn(&monitor_cmd.step);
}
