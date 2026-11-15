//! A private certificate authority for `tls = true` without a real
//! certificate (the mkcert approach). The CA is created once and kept
//! in <data_dir>/tls/; trust its `ca.crt` on your machines once and
//! every server certificate it signs is accepted without warnings.
//! The server certificate is reissued on every start, so its names
//! always match the configuration.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const der = @import("der.zig");
const x509 = @import("x509.zig");
const Ecdsa = x509.Ecdsa;
const Oid = der.Oid;

const day_s: u64 = 24 * 60 * 60;
const ca_validity_s: u64 = 10 * 365 * day_s;
/// Within the 398-day limit browsers enforce for server certificates.
const server_validity_s: u64 = 397 * day_s;

// Fixed extension values (DER).
/// basicConstraints cA = TRUE, pathLen 0: signs servers, not CAs.
const ca_only = "\x30\x06\x01\x01\xff\x02\x01\x00";
/// basicConstraints cA = FALSE.
const not_ca = "\x30\x00";
/// keyUsage keyCertSign | cRLSign.
const cert_signing = "\x03\x02\x01\x06";
/// keyUsage digitalSignature.
const signing_only = "\x03\x02\x07\x80";
/// extKeyUsage serverAuth.
const server_auth = "\x30\x0a\x06\x08\x2b\x06\x01\x05\x05\x07\x03\x01";

/// PEM-encoded certificate and private key.
pub const Pair = struct {
    cert_pem: []const u8,
    key_pem: []const u8,
};

pub fn newAuthority(arena: Allocator, io: Io, now_s: u64) !Pair {
    const key_pair = Ecdsa.KeyPair.generate(io);
    const public_key = key_pair.public_key.toUncompressedSec1();
    const ca_name = try authorityName(arena, &public_key);
    const key_id = x509.keyId(&public_key);
    const cert = try x509.sign(arena, io, .{
        .issuer = ca_name,
        .subject = ca_name,
        .not_before_s = now_s -| day_s,
        .not_after_s = now_s + ca_validity_s,
        .public_key = public_key,
        .extensions = &.{
            try x509.extension(arena, Oid.basic_constraints, true, ca_only),
            try x509.extension(arena, Oid.key_usage, true, cert_signing),
            try x509.extension(
                arena,
                Oid.subject_key_id,
                false,
                try der.element(arena, der.Tag.octet_string, &key_id),
            ),
        },
    }, key_pair);
    return .{
        .cert_pem = try x509.certPem(arena, cert),
        .key_pem = try x509.keyPem(arena, key_pair),
    };
}

/// A server certificate for `hosts` (DNS names or IP literals),
/// signed by the CA whose key is `ca_key_pem`.
pub fn issueServer(
    arena: Allocator,
    io: Io,
    ca_key_pem: []const u8,
    hosts: []const []const u8,
    now_s: u64,
) !Pair {
    const ca = try x509.parseKeyPem(arena, ca_key_pem);
    const ca_public = ca.public_key.toUncompressedSec1();
    const key_pair = Ecdsa.KeyPair.generate(io);
    const ca_key_id = x509.keyId(&ca_public);
    const cert = try x509.sign(arena, io, .{
        .issuer = try authorityName(arena, &ca_public),
        .subject = try x509.name(arena, hosts[0]),
        .not_before_s = now_s -| day_s,
        .not_after_s = now_s + server_validity_s,
        .public_key = key_pair.public_key.toUncompressedSec1(),
        .extensions = &.{
            try x509.extension(arena, Oid.basic_constraints, false, not_ca),
            try x509.extension(arena, Oid.key_usage, true, signing_only),
            try x509.extension(arena, Oid.ext_key_usage, false, server_auth),
            try x509.extension(
                arena,
                Oid.subject_alt_name,
                false,
                try altNames(arena, hosts),
            ),
            try x509.extension(
                arena,
                Oid.authority_key_id,
                false,
                try der.sequence(arena, &.{
                    try der.element(arena, der.Tag.implicit(0), &ca_key_id),
                }),
            ),
        },
    }, ca);
    return .{
        .cert_pem = try x509.certPem(arena, cert),
        .key_pem = try x509.keyPem(arena, key_pair),
    };
}

/// "zerverg local CA 1a2b3c4d": derived from the CA key, so the
/// issuer name of every server certificate can be rebuilt from the
/// key alone, and two installs never share a name.
fn authorityName(arena: Allocator, public_key: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(public_key, &digest, .{});
    const cn = try std.fmt.allocPrint(arena, "zerverg local CA {x}", .{
        digest[0..4],
    });
    return x509.name(arena, cn);
}

/// subjectAltName: IP literals as iPAddress, the rest as dNSName.
fn altNames(arena: Allocator, hosts: []const []const u8) ![]u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (hosts) |host| {
        const entry = if (Io.net.IpAddress.parse(host, 0)) |ip| switch (ip) {
            .ip4 => |a| try der.element(arena, der.Tag.implicit(7), &a.bytes),
            .ip6 => |a| try der.element(arena, der.Tag.implicit(7), &a.bytes),
        } else |_| try der.element(arena, der.Tag.implicit(2), host);
        try names.append(arena, entry);
    }
    return der.sequence(arena, names.items);
}

test "issued certificate chains to the authority" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const now: u64 = 1_800_000_000;
    const ca = try newAuthority(arena, io, now);
    const hosts = [_][]const u8{ "localhost", "127.0.0.1", "box.lan" };
    const server = try issueServer(arena, io, ca.key_pem, &hosts, now);

    const Certificate = std.crypto.Certificate;
    const pem = @import("pem.zig");
    const ca_der = try pem.decode(arena, "CERTIFICATE", ca.cert_pem);
    const leaf_der = try pem.decode(arena, "CERTIFICATE", server.cert_pem);
    const ca_cert = try (Certificate{ .buffer = ca_der, .index = 0 }).parse();
    const leaf = try (Certificate{ .buffer = leaf_der, .index = 0 }).parse();
    try leaf.verify(ca_cert, now);
    try ca_cert.verify(ca_cert, now);
    try leaf.verifyHostName("box.lan");
    try std.testing.expectError(
        error.CertificateHostMismatch,
        leaf.verifyHostName("other.lan"),
    );
    _ = try x509.parseKeyPem(arena, server.key_pem);
}
