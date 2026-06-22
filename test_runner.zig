//! Simple test runner for the UEFI target (std.start's EfiMain calls main).
//! Runs each test through con_out, prints a result line per test, emits the
//! sentinel the host harness greps, then powers off via Runtime Services. No
//! port I/O, so it runs on every ISA.

const std = @import("std");
const builtin = @import("builtin");
const uefi = @import("uefi");

// Route std.log and panics through con_out so a panicking test still prints to
// the serial line before the watchdog times out.
pub const std_options = uefi.std_options;
pub const panic = uefi.panic;

// qemu_runner greps these exact lines to decide pass/fail.
const result_pass = "@@UEFI_ZIG_RESULT=PASS@@";
const result_fail = "@@UEFI_ZIG_RESULT=FAIL@@";

pub fn main() void {
    const w = uefi.init();
    const tests = builtin.test_functions;

    var failed: usize = 0;
    for (tests) |t| {
        w.print("RUN  {s} ... ", .{t.name}) catch {};
        if (t.func()) |_| {
            w.writeAll("ok\n") catch {};
        } else |err| {
            failed += 1;
            w.print("FAIL ({s})\n", .{@errorName(err)}) catch {};
        }
    }

    w.print("\n{d} tests, {d} passed, {d} failed\n", .{ tests.len, tests.len - failed, failed }) catch {};
    w.print("{s}\n", .{if (failed == 0) result_pass else result_fail}) catch {};
    uefi.flush();
    uefi.shutdown();
}
