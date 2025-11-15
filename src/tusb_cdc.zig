const std = @import("std");
const microzig = @import("microzig");
const rp2xxx = microzig.hal;
const time = rp2xxx.time;
const gpio = rp2xxx.gpio;
const exports = rp2xxx.tinyusb_exports;
const peripherals = microzig.chip.peripherals;
const resets = rp2xxx.resets;

comptime {
    _ = exports;
}

const tinyusb = @import("tinyusb");

const led = gpio.num(25);
const button = gpio.num(9);

const uart = rp2xxx.uart.instance.num(0);
const uart_tx_pin = gpio.num(0);
const uart_rx_pin = gpio.num(1);

const MAGICREBOOTCODE: u8 = 0xAB;

pub const microzig_options = microzig.Options{
    .log_level = .debug,
    .logFn = rp2xxx.uart.log,
    .interrupts = .{ .USBCTRL_IRQ = .{ .c = exports.irq_handler } },
};

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    std.log.err("panics: {s}", .{message});
    @breakpoint();
    while (true) {}
}

pub fn main() !void {

    // Setup LED for blinking
    led.set_function(.sio);
    led.set_direction(.out);
    led.put(1);

    // Setup uart for logging and fast reset to bootloader
    uart_tx_pin.set_function(.uart);
    uart_rx_pin.set_function(.uart);
    uart.apply(.{
        .clock_config = rp2xxx.clock_config,
    });
    rp2xxx.uart.init_logger(uart);
    _ = tinyusb.tud_init(0);
    // std.log.info("USB DONE state: {}", .{peripherals.RESETS.RESET_DONE.read().USBCTRL});
    // std.log.info("USB Reset state: {}", .{peripherals.RESETS.RESET.read().USBCTRL});
    std.log.info("TUSB init done!", .{});

    // Initialize the loop
    var i: u32 = 0;
    var next_time = time.get_time_since_boot().add_duration(.from_ms(500));
    while (true) {
        tinyusb.tud_task();
        uart_read() catch {}; // Check for the reboot code.  Ignore errors.
        if (next_time.is_reached_by(time.get_time_since_boot())) {
            cdc_task();
            next_time = time.get_time_since_boot().add_duration(.from_ms(500));
            std.log.info("tick {}", .{i});
            led.toggle();
            i += 1;
        }
    }
}

fn uart_read() !void {
    const v = uart.read_word() catch {
        uart.clear_errors();
        return;
    };
    if (v == MAGICREBOOTCODE) {
        std.log.warn("Reboot cmd received", .{});
        microzig.hal.rom.reset_to_usb_boot();
    }
}

var cdc_buf: [128]u8 = undefined;
fn cdc_task() void {
    // connected() check for DTR bit
    // Most but not all terminal client set this when making connection
    if (tinyusb.tud_cdc_connected()) {
        // connected and there are data available
        if (tinyusb.tud_cdc_available() != 0) {
            // read data
            const count = tinyusb.tud_cdc_read(&cdc_buf, cdc_buf.len);

            // Echo back
            // Note: Skip echo by commenting out write() and write_flush()
            _ = tinyusb.tud_cdc_write(&cdc_buf, count);
            _ = tinyusb.tud_cdc_write_flush();
        } else {
            const str = "HEREANDTHERE\n\r";
            _ = tinyusb.tud_cdc_write(str, str.len);
            _ = tinyusb.tud_cdc_write_flush();
        }
    }
}
