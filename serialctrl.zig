/// This give pretty minimal functionality to find the device and print (in blue) messages from the vid/pid USB serial device
/// It can also send a "magic" code back to the device to force a reboot (device must be configured to handle this)
/// This file is intended as part of a build flow for a fast, single button development loop with supported HW setups (see readme).
/// Intended to be adapted for different development scenarios as needed.
const std = @import("std");
const serial = @import("serial");
const config = @import("config");
const builtin = @import("builtin");

// To do timeout stuff?
const VTIME = 5;
const VMIN = 6;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Looking for "reboot" argument only for now
    var force_reboot: bool = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "reboot")) {
            force_reboot = true;
        }
    }
    // Try to connect to serial device...
    // Searches based on provided build options in config import (see build.zig)
    var port_p: serial.PortInformation = undefined;
    var iter = try serial.list_info();
    while (try iter.next()) |port| {
        if (port.vid != 0)
            std.debug.print("Found Port: {s}\n    vid pid: 0x{x} 0x{x}\n", .{ port.description, port.vid, port.pid });

        if (port.vid == config.vid and port.pid == config.pid) {
            port_p = port;
            break;
        }
    } else {
        std.debug.print("Failed Device Not Found.\n    Searching: 0x{x}, 0x{x}\n", .{ config.vid, config.pid });
        return;
    }
    var port_comm = try std.fs.cwd().openFile(port_p.system_location, .{ .mode = .read_write });
    defer port_comm.close();

    // These probably need to align with the device side communication.
    try serial.configureSerialPort(port_comm, serial.SerialConfig{
        .baud_rate = 115200,
        .word_size = .eight,
        .parity = .none,
        .stop_bits = .one,
        .handshake = .none,
    });

    if (force_reboot) {
        try sendRestart(port_comm);
        // TODO: the timeout logging seems to cause unexpected phantom reads???
        // try startLogging(port_comm, 3);
        std.Thread.sleep(1 * std.time.ns_per_s);
        return; //error{DeviceNotFound}.DeviceNotFound;
    }
    try startLogging(port_comm, 0);
}

const magic_cmd = [_]u8{config.rebootcmd};
fn sendRestart(port: std.fs.File) !void {
    std.debug.print("Trying to force reboot...\n", .{});
    try port.writeAll(&magic_cmd);
}
const BUFFERSIZE = 4096; // arbitrary...
fn startLogging(port: std.fs.File, timeout_s: u8) !void {
    std.debug.print("Monitoring output...\n", .{});
    if (timeout_s > 0) {
        try setTimeout(port, timeout_s);
        std.debug.print("Setting timeout: {}s\n", .{timeout_s});
    }
    defer std.debug.print("Timeout Triggered!\n", .{});

    var file_buffer: [BUFFERSIZE]u8 = undefined;
    var reader = port.reader(&file_buffer);
    while (try reader.interface.takeDelimiter('\n')) |line| {
        std.debug.print("\x1b[94m{s}\x1b[0m\n", .{line});
    }
}

fn setTimeout(port: std.fs.File, timeout_s: u8) !void {
    // timeout when data is not available rather than stall
    // https://www.reddit.com/r/Zig/comments/1fjt883/setting_timeout_on_readbyte/
    switch (builtin.os.tag) {
        // .windows => {
        //     // TODO see https://www.reddit.com/r/Zig/comments/1fjt883/setting_timeout_on_readbyte/
        // },
        .linux, .macos => {
            var settings = try std.posix.tcgetattr(port.handle);
            settings.cc[VMIN] = 0;
            settings.cc[VTIME] = timeout_s *| 10; // VTIME is in 100ms increments
            try std.posix.tcsetattr(port.handle, .NOW, settings);
        },
        else => @compileError("unsupported OS, please implement!"),
    }
}
