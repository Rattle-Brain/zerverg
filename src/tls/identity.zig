//! Where the server certificate comes from: the configured PEM files,
//! or the local certificate authority kept in <data_dir>/tls/ (see
//! local_ca.zig), which signs a fresh server certificate each start.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Config = @import("../config.zig").Config;
const engine = @import("engine.zig");
const local_ca = @import("local_ca.zig");
const files = @import("../store/files.zig");

const max_pem_bytes = 1024 * 1024;
const tls_dir = "tls";
const ca_cert = "ca.crt";
const ca_key = "ca.key";
const server_cert = "server.crt";
const server_key = "server.key";

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
        try issueLocal(arena, io, config);
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
) !local_ca.Pair {
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

/// Creates the local CA on first use, then signs a server
/// certificate for this start. Both are written to <data_dir>/tls/.
fn issueLocal(arena: Allocator, io: Io, config: Config) !local_ca.Pair {
    var root = try Io.Dir.cwd().openDir(io, config.data_dir, .{});
    defer root.close(io);
    try root.createDirPath(io, tls_dir);
    var dir = try root.openDir(io, tls_dir, .{});
    defer dir.close(io);

    const now: u64 = @intCast(Io.Clock.real.now(io).toSeconds());
    const ca = try loadOrCreateAuthority(arena, io, dir, now);
    const hosts = try hostNames(arena, config.tls_hosts);
    const server =
        try local_ca.issueServer(arena, io, ca.key_pem, hosts, now);
    try files.writeAtomicPrivate(io, dir, server_key, server.key_pem);
    try files.writeAtomic(io, dir, server_cert, server.cert_pem);
    warnLocalCa(config.data_dir, try std.mem.join(arena, ", ", hosts));
    return server;
}

fn loadOrCreateAuthority(
    arena: Allocator,
    io: Io,
    dir: Io.Dir,
    now: u64,
) !local_ca.Pair {
    const limit: Io.Limit = .limited(max_pem_bytes);
    const cert = dir.readFileAlloc(io, ca_cert, arena, limit);
    const key = dir.readFileAlloc(io, ca_key, arena, limit);
    if (cert) |cert_pem| {
        return .{ .cert_pem = cert_pem, .key_pem = try key };
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const ca = try local_ca.newAuthority(arena, io, now);
    try files.writeAtomicPrivate(io, dir, ca_key, ca.key_pem);
    try files.writeAtomic(io, dir, ca_cert, ca.cert_pem);
    std.log.info("tls: created a local certificate authority", .{});
    return ca;
}

/// localhost, loopback IPs, this machine's name, then `extra`.
fn hostNames(
    arena: Allocator,
    extra: []const []const u8,
) ![]const []const u8 {
    var hosts: std.ArrayList([]const u8) = .empty;
    try hosts.appendSlice(arena, &.{ "localhost", "127.0.0.1", "::1" });
    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    if (std.posix.gethostname(&buf)) |name| {
        if (name.len > 0 and !std.mem.eql(u8, name, "localhost")) {
            try hosts.append(arena, try arena.dupe(u8, name));
            const local = try std.fmt.allocPrint(arena, "{s}.local", .{name});
            try hosts.append(arena, local);
        }
    } else |_| {}
    try hosts.appendSlice(arena, extra);
    return hosts.items;
}

fn warnLocalCa(data_dir: []const u8, hosts: []const u8) void {
    std.log.warn(
        \\
        \\  ************************************************************
        \\  * TLS with zerverg's LOCAL CERTIFICATE AUTHORITY.          *
        \\  * Browsers warn until you trust its certificate once (see  *
        \\  * README, "trusting the local certificate"). For a public  *
        \\  * site set tls_cert_file and tls_key_file instead.         *
        \\  ************************************************************
        \\  trust this file: {s}/{s}/{s}
        \\  server certificate valid for: {s}
    , .{ data_dir, tls_dir, ca_cert, hosts });
}
