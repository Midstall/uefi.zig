//! uefi - one per-target console a program opts into from its root source file.
//! std.log, panics, and plain data all reach a single writer: con_out on UEFI,
//! stdout everywhere else.
//!
//! Opt in from the root source file:
//!
//!     const uefi = @import("uefi");
//!     pub const std_options: std.Options = uefi.std_options; // routes std.log.*
//!     pub const panic = uefi.panic;                          // routes panics
//!
//! Call `uefi.init()` once at entry; it returns the active `*std.Io.Writer`. On
//! the host that writer is buffered, so `flush()` before exit. std.debug.print
//! is not routable on UEFI; use std.log or `uefi.writer()`.

const std = @import("std");
const builtin = @import("builtin");

const Writer = std.Io.Writer;

pub const is_uefi = builtin.os.tag == .uefi;

const uefi_ns = std.os.uefi;

/// Encode `bytes` (UTF-8) to UTF-16, translating a bare '\n' to "\r\n", and call
/// `emit(ctx, chunk)` for each filled, NUL-terminated chunk (the slice excludes
/// the NUL). No allocator: a fixed [buf_units:0]u16 buffer is flushed before any
/// unit that might need two slots, so every chunk stays valid.
pub fn encodeUtf16(
    comptime buf_units: usize,
    bytes: []const u8,
    ctx: anytype,
    comptime emit: fn (@TypeOf(ctx), [:0]const u16) void,
) void {
    var buf: [buf_units:0]u16 = undefined;
    var n: usize = 0;
    for (bytes) |c| {
        if (n + 2 >= buf.len) {
            buf[n] = 0;
            emit(ctx, buf[0..n :0]);
            n = 0;
        }
        if (c == '\n') {
            buf[n] = '\r';
            n += 1;
        }
        buf[n] = c;
        n += 1;
    }
    if (n > 0) {
        buf[n] = 0;
        emit(ctx, buf[0..n :0]);
    }
}

// Chunk buffer size: 256 code units plus the sentinel.
const chunk_units = 256;

/// A std.Io.Writer over EFI SimpleTextOutput. Unbuffered: the drain runs each
/// slice through encodeUtf16 into con_out. `con` is nullable so an absent
/// con_out (or a non-uefi target) drains to nothing rather than faulting.
pub const Console = struct {
    writer: Writer,
    con: if (is_uefi) ?*uefi_ns.protocol.SimpleTextOutput else void,

    const vtable: Writer.VTable = .{ .drain = drain };

    fn emitChunk(self: *Console, chunk: [:0]const u16) void {
        if (is_uefi) {
            const con = self.con orelse return;
            _ = con.outputString(chunk) catch {};
        }
    }

    fn emit(self: *Console, bytes: []const u8) void {
        const S = struct {
            fn sink(s: *Console, chunk: [:0]const u16) void {
                s.emitChunk(chunk);
            }
        };
        encodeUtf16(chunk_units, bytes, self, S.sink);
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *Console = @alignCast(@fieldParentPtr("writer", w));
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            self.emit(slice);
            written += slice.len;
        }
        const pattern = data[data.len - 1];
        var i: usize = 0;
        while (i < splat) : (i += 1) self.emit(pattern);
        written += splat * pattern.len;
        return written;
    }
};

// Host writer state: a buffered std.Io.File.Writer over stdout. Module scope so
// the returned *Writer stays valid for the program's lifetime.
var stdout_buf: [4096]u8 = undefined;
var threaded: std.Io.Threaded = undefined;
var file_writer: std.Io.File.Writer = undefined;

// The shared UEFI con_out console.
var console: Console = undefined;

// The active writer for this target, set by init(); null until then.
var current: ?*Writer = null;

/// Set up and return the active `*std.Io.Writer` for this target. Call once at
/// entry. UEFI: resets con_out and returns its unbuffered writer (draining to
/// nothing if con_out is absent). Host: returns a buffered stdout writer, so
/// remember to `flush()` before exit or buffered output is lost.
pub fn init() *Writer {
    if (is_uefi) {
        const con = uefi_ns.system_table.con_out;
        if (con) |c| _ = c.reset(false) catch {};
        console = .{ .writer = .{ .vtable = &Console.vtable, .buffer = &.{} }, .con = con };
        current = &console.writer;
        return &console.writer;
    } else {
        threaded = std.Io.Threaded.init(std.mem.Allocator.failing, .{});
        file_writer = std.Io.File.stdout().writer(threaded.io(), &stdout_buf);
        current = &file_writer.interface;
        return current.?;
    }
}

/// The active writer for this target, lazily calling init() the first time.
pub fn writer() *Writer {
    return current orelse init();
}

/// Flush the active writer. A no-op on UEFI (con_out is unbuffered); on the host
/// it drains the buffered stdout writer.
pub fn flush() void {
    const w = current orelse return;
    w.flush() catch {};
}

/// Spin forever with the output left on screen, so a UEFI app does not return
/// to firmware before the output can be read.
pub fn halt() noreturn {
    writer().print("\n>>> HALTED - read or photograph the output above, then power-cycle. <<<\n", .{}) catch {};
    flush();
    while (true) {
        if (is_uefi) asm volatile ("");
    }
}

/// Power off via UEFI Runtime Services (ACPI on x86, PSCI on ARM, SBI on
/// RISC-V), so under QEMU this terminates the VM. Falls back to halt() on a
/// non-uefi target. The test harness uses this to end a run.
pub fn shutdown() noreturn {
    if (is_uefi) {
        uefi_ns.system_table.runtime_services.resetSystem(.shutdown, .success, null);
    }
    halt();
}

/// std.Options whose logFn routes std.log.* to con_out, formatted like std's
/// defaultLog ("level(scope): message\n") minus the ANSI colours con_out lacks.
pub const std_options: std.Options = .{
    .logFn = logFn,
};

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const w = writer();
    w.writeAll(level.asText()) catch {};
    if (scope != .default) {
        w.print("({t})", .{scope}) catch {};
    }
    w.writeAll(": ") catch {};
    w.print(format ++ "\n", args) catch {};
}

/// The 0.16 panic namespace: a FullPanic that writes the message to con_out then
/// halts.
pub const panic = std.debug.FullPanic(panicFn);

fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    const w = writer();
    w.print("\n>>> PANIC: {s}\n", .{msg}) catch {};
    halt();
}

// Tests run inside QEMU under real firmware (see build.zig). std.heap
// .page_allocator (and so std.testing.allocator) is unavailable on UEFI, so
// use UEFI pool memory there and the testing allocator on a host build.
const test_allocator = if (is_uefi) uefi_ns.pool_allocator else std.testing.allocator;

// std.testing's assertions pull in std.debug's stderr machinery, which does not
// compile on UEFI. These helpers just return an error on mismatch; the test
// runner prints the failing test's name and error.
const expect = struct {
    fn ok(cond: bool) !void {
        if (!cond) return error.TestUnexpectedResult;
    }
    fn eql(comptime T: type, expected: T, actual: T) !void {
        if (expected != actual) return error.TestUnexpectedResult;
    }
    fn eqlSlices(comptime T: type, expected: []const T, actual: []const T) !void {
        if (expected.len != actual.len) return error.TestUnexpectedResult;
        for (expected, actual) |e, a| if (e != a) return error.TestUnexpectedResult;
    }
};

const TestSink = struct {
    out: std.ArrayList(u16),

    fn append(self: *TestSink, chunk: [:0]const u16) void {
        self.out.appendSlice(test_allocator, chunk) catch unreachable;
    }
};

fn encodeToOwned(bytes: []const u8) ![]u16 {
    var sink = TestSink{ .out = .empty };
    encodeUtf16(chunk_units, bytes, &sink, TestSink.append);
    return sink.out.toOwnedSlice(test_allocator);
}

test "utf16 translation expands LF to CRLF" {
    const got = try encodeToOwned("ab\nc");
    defer test_allocator.free(got);
    const want = [_]u16{ 'a', 'b', '\r', '\n', 'c' };
    try expect.eqlSlices(u16, &want, got);
}

test "utf16 translation leaves non-newline bytes alone" {
    const got = try encodeToOwned("x: 0xFF");
    defer test_allocator.free(got);
    const want = [_]u16{ 'x', ':', ' ', '0', 'x', 'F', 'F' };
    try expect.eqlSlices(u16, &want, got);
}

test "utf16 translation chunks a long line and still ends in CRLF" {
    // Longer than one chunk buffer (256 units): force the chunk-flush path and
    // confirm the trailing '\n' still becomes "\r\n" and nothing is dropped.
    var buf: [600]u8 = undefined;
    for (0..599) |i| buf[i] = 'A';
    buf[599] = '\n';
    const got = try encodeToOwned(&buf);
    defer test_allocator.free(got);
    // 599 'A' + "\r\n" = 601 code units.
    try expect.eql(usize, 601, got.len);
    try expect.eql(u16, 'A', got[0]);
    try expect.eql(u16, '\r', got[599]);
    try expect.eql(u16, '\n', got[600]);
}

test "init() returns the active writer and formats without faulting" {
    const w = init();
    try expect.ok(@TypeOf(w) == *Writer);
    try w.print("test: 0x{x} {d}\n", .{ @as(u32, 0xcafef00d), @as(u32, 42) });
    flush();
}

test "writer() lazily inits and returns the same active writer" {
    const a = writer();
    const b = writer();
    try expect.eql(*Writer, a, b);
    flush();
}

test "std_options + panic are the documented 0.16 shapes" {
    try expect.ok(@TypeOf(std_options) == std.Options);
    try expect.ok(@TypeOf(panic) == type);
    try expect.ok(@hasDecl(panic, "call"));
}
