//! Where the server certificate comes from: the configured PEM files,
//! or a self-signed pair generated once and kept in <data_dir>/tls/.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Config = @import("../config.zig").Config;
const engine = @import("engine.zig");
const self_signed = @import("self_signed.zig");
const files = @import("../store/files.zig");

const max_pem_bytes = 1024 * 1024;
const self_signed_dir = "tls";
const self_signed_cert = "self-signed.crt";
const self_signed_key = "self-signed.key";

/// Loads the identity the TLS listeners present.
pub fn load(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    config: Config,
) !engine.Identity {
    const pair = if (config.tls_cert_file.len > 0)
        try readConfigured(arena, io, config)
    else
        try loadSelfSigned(arena, io, config.data_dir);
    const cert = pair.cert_pem;
    return engine.Identity.fromPem(gpa, io, cert, pair.key_pem) catch |err| {
        std.log.err("tls: unusable certificate or key: {t}", .{err});
        return err;
    };
}

fn readConfigured(
    arena: Allocator,
    io: Io,
    config: Config,
) !self_signed.Pair {
    const cwd = Io.Dir.cwd();
    const limit: Io.Limit = .limited(max_pem_bytes);
    const cert = cwd.readFileAlloc(io, config.tls_cert_file, arena, limit);
    const key = cwd.readFileAlloc(io, config.tls_key_file, arena, limit);
    std.log.info("tls: certificate {s}", .{config.tls_cert_file});
    return .{
        .cert_pem = cert catch |err| return logReadError(
            config.tls_cert_file,
            err,
        ),
        .key_pem = key catch |err| return logReadError(
            config.tls_key_file,
            err,
        ),
    };
}

fn logReadError(path: []const u8, err: anyerror) anyerror {
    std.log.err("tls: cannot read {s}: {t}", .{ path, err });
    return err;
}

/// Reuses the stored self-signed pair (so a browser exception keeps
/// working across restarts) or generates one.
fn loadSelfSigned(
    arena: Allocator,
    io: Io,
    data_dir: []const u8,
) !self_signed.Pair {
    var root = try Io.Dir.cwd().openDir(io, data_dir, .{});
    defer root.close(io);
    try root.createDirPath(io, self_signed_dir);
    var dir = try root.openDir(io, self_signed_dir, .{});
    defer dir.close(io);

    warnSelfSigned(data_dir);
    const limit: Io.Limit = .limited(max_pem_bytes);
    const cert = dir.readFileAlloc(io, self_signed_cert, arena, limit);
    const key = dir.readFileAlloc(io, self_signed_key, arena, limit);
    if (cert) |cert_pem| {
        return .{ .cert_pem = cert_pem, .key_pem = try key };
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const now: u64 = @intCast(Io.Clock.real.now(io).toSeconds());
    const pair = try self_signed.generate(arena, io, now);
    try files.writeAtomicPrivate(io, dir, self_signed_key, pair.key_pem);
    try files.writeAtomic(io, dir, self_signed_cert, pair.cert_pem);
    std.log.info("tls: generated a new self-signed certificate", .{});
    return pair;
}

fn warnSelfSigned(data_dir: []const u8) void {
    std.log.warn(
        \\
        \\  ************************************************************
        \\  * TLS with a SELF-SIGNED certificate: browsers will warn.  *
        \\  * For a public site set tls_cert_file and tls_key_file     *
        \\  * (e.g. Let's Encrypt fullchain.pem and privkey.pem).      *
        \\  ************************************************************
        \\  certificate: {s}/{s}/{s}
    , .{ data_dir, self_signed_dir, self_signed_cert });
}
