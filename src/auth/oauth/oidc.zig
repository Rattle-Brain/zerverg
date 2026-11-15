//! OpenID Connect: discovery, token exchange and ID token claims.
//! Works with Google, Microsoft, GitLab, Keycloak, Authentik, ...

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const OAuthProvider = @import("../../config.zig").OAuthProvider;
const fetch = @import("fetch.zig");
const Identity = @import("identity.zig").Identity;

const clock_skew_s = 60;

/// The endpoints an issuer publishes. Owns its strings.
pub const Discovery = struct {
    arena: std.heap.ArenaAllocator,
    issuer: []const u8,
    authorization_endpoint: []const u8,
    token_endpoint: []const u8,
    jwks_uri: []const u8,

    pub fn deinit(self: *Discovery) void {
        self.arena.deinit();
    }
};

pub const Error = error{
    InvalidDiscovery,
    InvalidIdToken,
    AccountNotVerified,
} || fetch.Error;

/// Fetches `<issuer>/.well-known/openid-configuration`. The document
/// must name exactly the configured issuer, and every endpoint must
/// be HTTPS: a tampered document cannot redirect us elsewhere.
pub fn discover(gpa: Allocator, io: Io, issuer: []const u8) !Discovery {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const url = try std.fmt.allocPrint(
        a,
        "{s}/.well-known/openid-configuration",
        .{issuer},
    );
    const body = try fetch.json(gpa, io, a, .{ .url = url });
    const Doc = struct {
        issuer: []const u8,
        authorization_endpoint: []const u8,
        token_endpoint: []const u8,
        jwks_uri: []const u8,
    };
    const doc = std.json.parseFromSliceLeaky(Doc, a, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.InvalidDiscovery;
    if (!std.mem.eql(u8, doc.issuer, issuer)) return error.InvalidDiscovery;
    for ([_][]const u8{
        doc.authorization_endpoint, doc.token_endpoint, doc.jwks_uri,
    }) |endpoint| {
        if (!fetch.isAllowedUrl(endpoint)) return error.InvalidDiscovery;
    }
    return .{
        .arena = arena,
        .issuer = doc.issuer,
        .authorization_endpoint = doc.authorization_endpoint,
        .token_endpoint = doc.token_endpoint,
        .jwks_uri = doc.jwks_uri,
    };
}

/// Trades the authorization code for an ID token (back channel).
pub fn exchangeCode(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    token_endpoint: []const u8,
    form: []const u8,
) Error![]const u8 {
    const body = try fetch.json(gpa, io, arena, .{
        .url = token_endpoint,
        .form = form,
    });
    const Reply = struct { id_token: []const u8 = "" };
    const reply = std.json.parseFromSliceLeaky(Reply, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.InvalidIdToken;
    if (reply.id_token.len == 0) return error.InvalidIdToken;
    return reply.id_token;
}

pub const Expected = struct {
    issuer: []const u8,
    client_id: []const u8,
    nonce: []const u8,
    now_s: i64,
};

/// Validates the claims of a signature-checked ID token
/// (OIDC Core 3.1.3.7) and returns who it identifies.
pub fn checkClaims(
    arena: Allocator,
    claims_json: []const u8,
    expected: Expected,
) Error!Identity {
    const Claims = struct {
        iss: []const u8,
        aud: std.json.Value,
        azp: []const u8 = "",
        sub: []const u8,
        exp: i64,
        iat: i64 = 0,
        nonce: []const u8 = "",
        email: []const u8 = "",
        email_verified: std.json.Value = .null,
    };
    const c = std.json.parseFromSliceLeaky(Claims, arena, claims_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.InvalidIdToken;
    const ok = std.mem.eql(u8, c.iss, expected.issuer) and
        audienceContains(c.aud, expected.client_id) and
        (c.azp.len == 0 or std.mem.eql(u8, c.azp, expected.client_id)) and
        c.exp + clock_skew_s > expected.now_s and
        c.iat - clock_skew_s < expected.now_s and
        c.sub.len > 0 and
        std.mem.eql(u8, c.nonce, expected.nonce);
    if (!ok) return error.InvalidIdToken;
    return .{
        .subject = c.sub,
        .email = c.email,
        .email_verified = isTrue(c.email_verified),
    };
}

fn audienceContains(aud: std.json.Value, client_id: []const u8) bool {
    switch (aud) {
        .string => |s| return std.mem.eql(u8, s, client_id),
        .array => |list| for (list.items) |item| {
            if (item == .string and std.mem.eql(u8, item.string, client_id)) {
                return true;
            }
        },
        else => {},
    }
    return false;
}

/// Some providers send `"email_verified": "true"`.
fn isTrue(value: std.json.Value) bool {
    return switch (value) {
        .bool => |b| b,
        .string => |s| std.mem.eql(u8, s, "true"),
        else => false,
    };
}

test "claims" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nonce = "n" ** 43;
    const expected: Expected = .{
        .issuer = "https://issuer.test",
        .client_id = "client-1",
        .nonce = nonce,
        .now_s = 1_800_000_000,
    };
    const good =
        \\{"iss":"https://issuer.test","aud":["x","client-1"],"sub":"42",
        \\"exp":1800000100,"iat":1799999990,"nonce":"
    ++ nonce ++
        \\","email":"me@x.test","email_verified":"true"}
    ;
    const id = try checkClaims(arena, good, expected);
    try std.testing.expect(id.email_verified);

    var wrong_nonce = expected;
    wrong_nonce.nonce = "m" ** 43;
    try std.testing.expectError(
        error.InvalidIdToken,
        checkClaims(arena, good, wrong_nonce),
    );
    var expired = expected;
    expired.now_s = 1_900_000_000;
    try std.testing.expectError(
        error.InvalidIdToken,
        checkClaims(arena, good, expired),
    );
}
