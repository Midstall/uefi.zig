const std = @import("std");

// How QEMU loads the firmware: x86 uses -bios, the virt machines use pflash.
const Firmware = enum { bios, pflash };

const ArchConfig = struct {
    qemu_bin: []const u8,
    machine: []const u8,
    // EFI/BOOT/<boot_file>: the removable-media path firmware auto-boots.
    boot_file: []const u8,
    firmware: Firmware,
    cpu: ?[]const u8 = null,
};

// One entry per architecture UEFI and QEMU both support.
fn archConfig(arch: std.Target.Cpu.Arch) ?ArchConfig {
    return switch (arch) {
        .x86_64 => .{
            .qemu_bin = "qemu-system-x86_64",
            .machine = "q35",
            .boot_file = "BOOTX64.EFI",
            .firmware = .bios,
        },
        .x86 => .{
            .qemu_bin = "qemu-system-i386",
            .machine = "q35",
            .boot_file = "BOOTIA32.EFI",
            .firmware = .bios,
        },
        .aarch64 => .{
            .qemu_bin = "qemu-system-aarch64",
            .machine = "virt",
            .boot_file = "BOOTAA64.EFI",
            .firmware = .pflash,
            .cpu = "cortex-a57",
        },
        .arm => .{
            .qemu_bin = "qemu-system-arm",
            .machine = "virt",
            .boot_file = "BOOTARM.EFI",
            .firmware = .pflash,
            .cpu = "cortex-a15",
        },
        .riscv64 => .{
            .qemu_bin = "qemu-system-riscv64",
            .machine = "virt",
            .boot_file = "BOOTRISCV64.EFI",
            .firmware = .pflash,
        },
        .loongarch64 => .{
            .qemu_bin = "qemu-system-loongarch64",
            .machine = "virt",
            .boot_file = "BOOTLOONGARCH64.EFI",
            .firmware = .pflash,
        },
        else => null,
    };
}

pub fn build(b: *std.Build) void {
    // Default to x86_64 UEFI; -Dtarget=<arch>-uefi picks another architecture.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .uefi },
    });
    const optimize = b.standardOptimizeOption(.{});

    const ovmf_opt = b.option([]const u8, "ovmf", "Path to the UEFI firmware image (OVMF/AAVMF .fd) for the test target");
    const timeout = b.option(u32, "test-timeout", "Seconds before a hung QEMU guest is killed (default 60)") orelse 60;

    const uefi_mod = b.addModule("uefi", .{
        .root_source_file = b.path("lib/uefi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run uefi tests in QEMU");

    const result = target.result;
    if (result.os.tag != .uefi) {
        test_step.dependOn(&b.addFail(b.fmt(
            "test target must be UEFI (got '{s}-{s}'); pass e.g. -Dtarget=x86_64-uefi",
            .{ @tagName(result.cpu.arch), @tagName(result.os.tag) },
        )).step);
        return;
    }

    const cfg = archConfig(result.cpu.arch) orelse {
        test_step.dependOn(&b.addFail(b.fmt(
            "unsupported test architecture '{s}'. Supported: x86_64, x86, aarch64, arm, riscv64, loongarch64",
            .{@tagName(result.cpu.arch)},
        )).step);
        return;
    };

    const ovmf = ovmf_opt orelse {
        test_step.dependOn(&b.addFail(b.fmt(
            "no firmware for '{s}-uefi'; pass -Dovmf=/path/to/firmware.fd",
            .{@tagName(result.cpu.arch)},
        )).step);
        return;
    };

    // The custom runner is the entry point; the library module supplies the
    // tests and is imported by the runner as "uefi".
    const test_exe = b.addTest(.{
        .name = "uefi-test",
        .root_module = uefi_mod,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    test_exe.root_module.addImport("uefi", uefi_mod);

    // Lay the binary out as an EFI System Partition in the build cache. QEMU
    // mounts it as a FAT image and auto-boots EFI/BOOT/<boot_file>.
    const esp = b.addWriteFiles();
    _ = esp.addCopyFile(test_exe.getEmittedBin(), b.fmt("EFI/BOOT/{s}", .{cfg.boot_file}));

    // Host launcher: spawns QEMU, enforces the timeout, reports pass/fail.
    const runner = b.addExecutable(.{
        .name = "qemu_runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("qemu_runner.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const qemu_path = b.findProgram(&.{cfg.qemu_bin}, &.{}) catch cfg.qemu_bin;

    const run = b.addRunArtifact(runner);
    run.addArg(b.fmt("{d}", .{timeout}));
    run.addArg(qemu_path);
    run.addArgs(&.{ "-machine", cfg.machine });
    if (cfg.cpu) |cpu| run.addArgs(&.{ "-cpu", cpu });
    run.addArgs(&.{ "-m", "256M", "-display", "none", "-no-reboot", "-serial", "stdio", "-net", "none" });
    switch (cfg.firmware) {
        .bios => run.addArgs(&.{ "-bios", ovmf }),
        .pflash => run.addArgs(&.{ "-drive", b.fmt("if=pflash,format=raw,unit=0,readonly=on,file={s}", .{ovmf}) }),
    }
    run.addArg("-drive");
    run.addPrefixedDirectoryArg("format=raw,file=fat:rw:", esp.getDirectory());

    test_step.dependOn(&run.step);
}
