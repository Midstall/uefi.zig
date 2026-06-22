//! Host launcher for `zig build test`. Spawns QEMU (no shell), streams the
//! guest serial to stdout, and decides pass/fail from the sentinel the test
//! runner prints. The poll() deadline stops the build hanging: if the guest
//! never powers off we kill QEMU and fail.
//!
//! Args (from build.zig): <timeout_secs> <qemu-binary> [qemu-args...]

const std = @import("std");
const posix = std.posix;

const result_pass = "@@UEFI_ZIG_RESULT=PASS@@";
const result_fail = "@@UEFI_ZIG_RESULT=FAIL@@";

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer it.deinit();
    _ = it.next();

    const timeout_str = it.next() orelse return usage("missing <timeout_secs>");
    const timeout_secs = std.fmt.parseInt(u32, timeout_str, 10) catch
        return usage("invalid <timeout_secs>");

    // Arena is freed at process exit, so the duped argv needs no cleanup.
    const aa = init.arena.allocator();
    var qemu_argv: std.ArrayList([]const u8) = .empty;
    while (it.next()) |a| try qemu_argv.append(aa, try aa.dupe(u8, a));
    if (qemu_argv.items.len == 0) return usage("missing QEMU command");

    std.debug.print("uefi.zig test: launching QEMU (timeout {d}s)\n  ", .{timeout_secs});
    for (qemu_argv.items) |a| std.debug.print("{s} ", .{a});
    std.debug.print("\n", .{});

    var child = std.process.spawn(io, .{
        .argv = qemu_argv.items,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    }) catch |err| {
        std.debug.print("uefi.zig test: failed to spawn QEMU ('{s}'): {t}\n", .{ qemu_argv.items[0], err });
        return 1;
    };

    const fd = child.stdout.?.handle;

    // Stream the guest serial to stdout as it arrives.
    var out_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout_w.interface;

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(gpa);

    const deadline_ns: i96 = std.Io.Timestamp.now(io, .awake).nanoseconds +
        @as(i96, timeout_secs) * std.time.ns_per_s;
    var buf: [4096]u8 = undefined;
    var timed_out = false;

    while (true) {
        const now_ns = std.Io.Timestamp.now(io, .awake).nanoseconds;
        if (now_ns >= deadline_ns) {
            timed_out = true;
            break;
        }
        const remaining_ms: i32 = @intCast(@min(
            @as(i96, std.math.maxInt(i32)),
            @divTrunc(deadline_ns - now_ns, std.time.ns_per_ms) + 1,
        ));

        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, remaining_ms) catch |err| {
            std.debug.print("uefi.zig test: poll failed: {t}\n", .{err});
            break;
        };
        if (ready == 0) {
            timed_out = true;
            break;
        }

        const n = posix.read(fd, &buf) catch |err| {
            std.debug.print("uefi.zig test: read failed: {t}\n", .{err});
            break;
        };
        if (n == 0) break; // EOF: QEMU closed its serial output, i.e. it exited.

        out.writeAll(buf[0..n]) catch {};
        out.flush() catch {};
        try captured.appendSlice(gpa, buf[0..n]);
    }
    out.flush() catch {};

    if (timed_out) {
        child.kill(io);
        std.debug.print(
            "\nuefi.zig test: TIMEOUT after {d}s - guest never powered off " ++
                "(hang, early crash, or firmware produced no serial output).\n",
            .{timeout_secs},
        );
        return 1;
    }

    const term = child.wait(io) catch |err| {
        std.debug.print("uefi.zig test: wait failed: {t}\n", .{err});
        return 1;
    };

    const saw_pass = std.mem.indexOf(u8, captured.items, result_pass) != null;
    const saw_fail = std.mem.indexOf(u8, captured.items, result_fail) != null;

    if (saw_pass and !saw_fail) return 0;

    if (saw_fail) {
        std.debug.print("\nuefi.zig test: a test FAILED (see serial output above).\n", .{});
    } else {
        std.debug.print(
            "\nuefi.zig test: no result sentinel - QEMU exited ({any}) before the tests reported.\n",
            .{term},
        );
    }
    return 1;
}

fn usage(msg: []const u8) u8 {
    std.debug.print("qemu_runner: {s}\n", .{msg});
    std.debug.print("usage: qemu_runner <timeout_secs> <qemu-binary> [qemu-args...]\n", .{});
    return 2;
}
