//! Builds and signs X.509 v3 certificates with ECDSA P-256 keys:
//! just what the local certificate authority needs.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const der = @import("der.zig");
const pem = @import("pem.zig");
const Tag = der.Tag;
const Oid = der.Oid;

pub const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
pub const PublicKey = [Ecdsa.PublicKey.uncompressed_sec1_encoded_length]u8;

/// Everything that goes into a certificate except the signature.
pub const Spec = struct {
    /// DER `Name`s, from `name`.
    issuer: []const u8,
    subject: []const u8,
    not_before_s: u64,
    not_after_s: u64,
    public_key: PublicKey,
    /// DER `Extension`s, from `extension`.
    extensions: []const []const u8,
};

/// Signs `spec` with `signer`; returns the DER certificate.
pub fn sign(
    arena: Allocator,
    io: Io,
    spec: Spec,
    signer: Ecdsa.KeyPair,
) ![]u8 {
    var serial: [16]u8 = undefined;
    io.random(&serial);
    serial[0] &= 0x7f;
    serial[0] |= 0x01; // positive and never all zero
    const tbs = try der.sequence(arena, &.{
        try der.element(arena, Tag.explicit(0), "\x02\x01\x02"), // v3
        try der.unsigned(arena, &serial),
        try signatureAlgorithm(arena),
        spec.issuer,
        try der.sequence(arena, &.{
            try der.time(arena, spec.not_before_s),
            try der.time(arena, spec.not_after_s),
        }),
        spec.subject,
        try subjectPublicKeyInfo(arena, &spec.public_key),
        try der.wrap(arena, Tag.explicit(3), &.{
            try der.sequence(arena, spec.extensions),
        }),
    });
    const signature = try signer.sign(tbs, null);
    var sig_buf: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    return der.sequence(arena, &.{
        tbs,
        try signatureAlgorithm(arena),
        try der.bitString(arena, signature.toDer(&sig_buf)),
    });
}

/// A `Name` with only a common name.
pub fn name(arena: Allocator, common_name: []const u8) ![]u8 {
    const attribute = try der.sequence(arena, &.{
        try der.oid(arena, Oid.common_name),
        try der.element(arena, Tag.utf8_string, common_name),
    });
    const rdn = try der.wrap(arena, Tag.set, &.{attribute});
    return der.sequence(arena, &.{rdn});
}

pub fn extension(
    arena: Allocator,
    id: []const u8,
    critical: bool,
    value: []const u8,
) ![]u8 {
    return der.sequence(arena, &.{
        try der.oid(arena, id),
        if (critical) "\x01\x01\xff" else "",
        try der.element(arena, Tag.octet_string, value),
    });
}

/// The key identifier used by subject/authority key id extensions:
/// SHA-1 of the public key (RFC 5280, 4.2.1.2 method 1).
pub fn keyId(public_key: []const u8) [20]u8 {
    var out: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(public_key, &out, .{});
    return out;
}

fn signatureAlgorithm(arena: Allocator) ![]u8 {
    return der.sequence(arena, &.{try der.oid(arena, Oid.ecdsa_with_sha256)});
}

fn subjectPublicKeyInfo(arena: Allocator, public_key: []const u8) ![]u8 {
    return der.sequence(arena, &.{
        try der.sequence(arena, &.{
            try der.oid(arena, Oid.ec_public_key),
            try der.oid(arena, Oid.prime256v1),
        }),
        try der.bitString(arena, public_key),
    });
}

/// SEC1 `ECPrivateKey` (RFC 5915) as PEM.
pub fn keyPem(arena: Allocator, key_pair: Ecdsa.KeyPair) ![]u8 {
    const secret = key_pair.secret_key.toBytes();
    const public_key = key_pair.public_key.toUncompressedSec1();
    const key = try der.sequence(arena, &.{
        "\x02\x01\x01", // version 1
        try der.element(arena, Tag.octet_string, &secret),
        try der.wrap(arena, Tag.explicit(0), &.{
            try der.oid(arena, Oid.prime256v1),
        }),
        try der.wrap(arena, Tag.explicit(1), &.{
            try der.bitString(arena, &public_key),
        }),
    });
    return pem.encode(arena, "EC PRIVATE KEY", key);
}

/// Reads back a key written by `keyPem`.
pub fn parseKeyPem(arena: Allocator, text: []const u8) !Ecdsa.KeyPair {
    const bytes = try pem.decode(arena, "EC PRIVATE KEY", text);
    const Element = std.crypto.Certificate.der.Element;
    const seq = try Element.parse(bytes, 0);
    const version = try Element.parse(bytes, seq.slice.start);
    const secret = try Element.parse(bytes, version.slice.end);
    const raw = bytes[secret.slice.start..secret.slice.end];
    if (raw.len != Ecdsa.SecretKey.encoded_length) return error.InvalidKey;
    const key = try Ecdsa.SecretKey.fromBytes(raw[0..32].*);
    return Ecdsa.KeyPair.fromSecretKey(key);
}

pub fn certPem(arena: Allocator, cert_der: []const u8) ![]u8 {
    return pem.encode(arena, "CERTIFICATE", cert_der);
}
