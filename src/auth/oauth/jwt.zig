//! JSON Web Tokens and key sets: exactly enough of RFC 7515/7517/7518
//! to verify OpenID Connect ID tokens.
//!
//! Only RS256 and ES256 are accepted. `none` and the HMAC family are
//! rejected outright: with HMAC, a public key could be abused as a
//! shared secret ("algorithm confusion"), so we never go there.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const rsa = std.crypto.Certificate.rsa;

pub const base64url = std.base64.url_safe_no_pad;

pub const Error = error{ InvalidToken, UnsupportedKey } || Allocator.Error;

pub const Token = struct {
    alg: []const u8,
    kid: []const u8,
    /// `header.claims`, the bytes the signature covers.
    signing_input: []const u8,
    claims_json: []const u8,
    signature: []const u8,
};

/// Splits and decodes a compact JWS. Does not verify anything.
pub fn decode(arena: Allocator, token: []const u8) Error!Token {
    if (token.len > 16 * 1024) return error.InvalidToken;
    var parts = std.mem.splitScalar(u8, token, '.');
    const header_b64 = parts.next() orelse return error.InvalidToken;
    const claims_b64 = parts.next() orelse return error.InvalidToken;
    const sig_b64 = parts.next() orelse return error.InvalidToken;
    if (parts.next() != null) return error.InvalidToken;

    const Header = struct { alg: []const u8, kid: []const u8 = "" };
    const header_json = try decodeB64(arena, header_b64);
    const header = std.json.parseFromSliceLeaky(Header, arena, header_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.InvalidToken;
    return .{
        .alg = header.alg,
        .kid = header.kid,
        .signing_input = token[0 .. header_b64.len + 1 + claims_b64.len],
        .claims_json = try decodeB64(arena, claims_b64),
        .signature = try decodeB64(arena, sig_b64),
    };
}

pub fn decodeB64(arena: Allocator, text: []const u8) Error![]u8 {
    const len = base64url.Decoder.calcSizeForSlice(text) catch
        return error.InvalidToken;
    const out = try arena.alloc(u8, len);
    base64url.Decoder.decode(out, text) catch return error.InvalidToken;
    return out;
}

pub const Key = struct {
    kid: []const u8,
    material: union(enum) {
        /// Big-endian modulus and exponent.
        rsa: struct { n: []const u8, e: []const u8 },
        ec: Ecdsa.PublicKey,
    },
};

/// Checks `token`'s signature with `key`. The algorithm must match
/// the key type; anything but RS256/ES256 fails.
pub fn verify(token: Token, key: Key) Error!void {
    switch (key.material) {
        .rsa => |k| {
            if (!std.mem.eql(u8, token.alg, "RS256")) return error.InvalidToken;
            return verifyRsa(token, k.n, k.e);
        },
        .ec => |public_key| {
            if (!std.mem.eql(u8, token.alg, "ES256")) return error.InvalidToken;
            if (token.signature.len != Ecdsa.Signature.encoded_length) {
                return error.InvalidToken;
            }
            const sig = Ecdsa.Signature.fromBytes(token.signature[0..64].*);
            sig.verify(token.signing_input, public_key) catch
                return error.InvalidToken;
        },
    }
}

fn verifyRsa(token: Token, n: []const u8, e: []const u8) Error!void {
    const public_key = rsa.PublicKey.fromBytes(e, n) catch
        return error.UnsupportedKey;
    const sig = token.signature;
    if (sig.len != n.len) return error.InvalidToken;
    switch (n.len) {
        inline 256, 384, 512 => |len| {
            rsa.PKCS1v1_5Signature.verify(
                len,
                sig[0..len].*,
                token.signing_input,
                public_key,
                Sha256,
            ) catch return error.InvalidToken;
        },
        else => return error.UnsupportedKey,
    }
}

/// A JSON Web Key Set, owning its memory.
pub const KeySet = struct {
    arena: std.heap.ArenaAllocator,
    keys: []const Key,

    pub fn parse(gpa: Allocator, json: []const u8) Error!KeySet {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const keys = try parseKeys(arena.allocator(), json);
        if (keys.len == 0) return error.UnsupportedKey;
        return .{ .arena = arena, .keys = keys };
    }

    pub fn deinit(self: *KeySet) void {
        self.arena.deinit();
    }

    pub fn find(self: *const KeySet, kid: []const u8) ?Key {
        for (self.keys) |key| {
            if (std.mem.eql(u8, key.kid, kid)) return key;
        }
        return null;
    }
};

const Jwk = struct {
    kty: []const u8,
    kid: []const u8 = "",
    use: []const u8 = "sig",
    n: []const u8 = "",
    e: []const u8 = "",
    crv: []const u8 = "",
    x: []const u8 = "",
    y: []const u8 = "",
};

fn parseKeys(arena: Allocator, json: []const u8) Error![]const Key {
    const set = std.json.parseFromSliceLeaky(
        struct { keys: []const Jwk },
        arena,
        json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch return error.UnsupportedKey;
    var keys: std.ArrayList(Key) = .empty;
    for (set.keys) |jwk| {
        if (!std.mem.eql(u8, jwk.use, "sig")) continue;
        const key = keyFromJwk(arena, jwk) catch continue;
        try keys.append(arena, key);
    }
    return keys.items;
}

fn keyFromJwk(arena: Allocator, jwk: Jwk) Error!Key {
    if (std.mem.eql(u8, jwk.kty, "RSA")) {
        const n = std.mem.trimStart(u8, try decodeB64(arena, jwk.n), "\x00");
        const e = try decodeB64(arena, jwk.e);
        return .{ .kid = jwk.kid, .material = .{ .rsa = .{ .n = n, .e = e } } };
    }
    if (std.mem.eql(u8, jwk.kty, "EC") and std.mem.eql(u8, jwk.crv, "P-256")) {
        const x = try decodeB64(arena, jwk.x);
        const y = try decodeB64(arena, jwk.y);
        if (x.len != 32 or y.len != 32) return error.UnsupportedKey;
        var sec1: [65]u8 = undefined;
        sec1[0] = 0x04;
        @memcpy(sec1[1..33], x);
        @memcpy(sec1[33..65], y);
        const public_key = Ecdsa.PublicKey.fromSec1(&sec1) catch
            return error.UnsupportedKey;
        return .{ .kid = jwk.kid, .material = .{ .ec = public_key } };
    }
    return error.UnsupportedKey;
}

// ------------------------------------------------------------------
// tests
// ------------------------------------------------------------------

const testing = std.testing;

// RSA-2048 key and RS256 token generated with openssl for this test.
const test_n =
    "qi3n7zpqsk6tlTImFKAQTf7MY9aA3iZsiD_DNVMqv2L-f5cFJF-uhfoRLAuA" ++
    "o2Xuz2biW3FmJkyF58xDUEM6CrI8USlp8mfoqDge1fiYIcGGMBJ6GGw8fmqI" ++
    "aMpLkczWPPrlP8Pl84LuMhdxVsGbHQYgH_omj5YxBpyf8LrOQPuaOPBXqzTx" ++
    "7aCUSDjlT28--QfJJVgq4SJtob8mVycpdrWfbRsN_Z2LS8WLQEcvVwb6jE7k" ++
    "76WYkLJQkmIzkE8iyNcCr7zKSuSXQFRnM5KkmMIh3FzSlkGqQwk6lwCZIURR" ++
    "By6UuU_pjGAFe7xnR6klfGO75L90Dkj4dbJMvN-BDw";
const test_token =
    "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3QtcnNhIiwidHlwIjoiSldUIn0." ++
    "eyJpc3MiOiJodHRwczovL2lzc3Vlci50ZXN0IiwiYXVkIjoiY2xpZW50LTEi" ++
    "LCJzdWIiOiI0MiIsImVtYWlsIjoibWVAeC50ZXN0IiwiZW1haWxfdmVyaWZp" ++
    "ZWQiOnRydWUsIm5vbmNlIjoibjBuY2UiLCJleHAiOjQxMDI0NDQ4MDAsImlh" ++
    "dCI6MTcwMDAwMDAwMH0.ovyFGe35pYn1hYVeM6OtVZ2MEeZ2bVAItgb_xUOj" ++
    "zZ4nDu2J0wsceKO7ta95pMr1ZOD5yOd6ofI8GAz2Vscw45Fju8cXPxQgiBKh" ++
    "OjZbOsvJqqRbrijAH9O4DWXxpn3pGG9iopILwZVMRbYZW9ObCkaeJtvwfpe-" ++
    "hKl4r--5uXi8un00rbJ-fXvlHm5MqfbzjH3Xk1oSebj4NMVtGTPKhfteceG_" ++
    "2mlEZk5tQnDh_w8AFQ37voOugcDt5awMTqWWF3V3SXb8TjP-4DnnnuH1dyne" ++
    "ivDgDGwBSIZv_ujFqvj5oJk8KO5m28zdrzpz9OmlOCmzmLEMVZPsXHtlrcoN" ++
    "5A";

test "RS256 token verifies against its JWK, and only that" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const jwks = "{\"keys\":[{\"kty\":\"RSA\",\"kid\":\"test-rsa\"," ++
        "\"e\":\"AQAB\",\"n\":\"" ++ test_n ++ "\"}]}";
    var set = try KeySet.parse(testing.allocator, jwks);
    defer set.deinit();

    const token = try decode(arena, test_token);
    try testing.expectEqualStrings("test-rsa", token.kid);
    try verify(token, set.find("test-rsa").?);

    var bad = token;
    bad.signing_input = "eyJhbGciOiJSUzI1NiJ9.e30";
    const key = set.find("test-rsa").?;
    try testing.expectError(error.InvalidToken, verify(bad, key));

    var confused = token;
    confused.alg = "HS256";
    try testing.expectError(
        error.InvalidToken,
        verify(confused, set.find("test-rsa").?),
    );
}

test "ES256 round trip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const kp = Ecdsa.KeyPair.generate(testing.io);
    const signing_input = "eyJhbGciOiJFUzI1NiJ9.e30";
    const sig = try kp.sign(signing_input, null);
    const token: Token = .{
        .alg = "ES256",
        .kid = "",
        .signing_input = signing_input,
        .claims_json = "{}",
        .signature = try arena.dupe(u8, &sig.toBytes()),
    };
    const key: Key = .{ .kid = "", .material = .{ .ec = kp.public_key } };
    try verify(token, key);
    var none = token;
    none.alg = "none";
    try testing.expectError(error.InvalidToken, verify(none, key));
}
