//! "Sign in with ...": the OAuth 2.0 authorization code flow with
//! PKCE (RFC 7636), plus OpenID Connect ID token validation.
//!
//! 1. `start`: remember a random state, PKCE verifier and nonce, and
//!    send the browser to the provider.
//! 2. `finish`: the provider sends the browser back with a code. We
//!    check the state is one we issued (single use, bound to the
//!    browser by a cookie), trade the code for tokens over a direct
//!    TLS connection, verify the ID token, and apply the allowlist.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const config = @import("../../config.zig");
const fetch = @import("fetch.zig");
const jwt = @import("jwt.zig");
const oidc = @import("oidc.zig");
const github = @import("github.zig");
const identity_mod = @import("identity.zig");
const Pending = @import("Pending.zig");

const OAuth = @This();

pub const Identity = identity_mod.Identity;

const keys_ttl_s = 60 * 60;
const min_refresh_interval_s = 30;

/// Per-provider caches, guarded by `mutex`.
const ProviderState = struct {
    discovery: ?oidc.Discovery = null,
    keys: ?jwt.KeySet = null,
    keys_fetched_s: i64 = 0,
    keys_attempted_s: i64 = 0,
};

pub const Error = error{
    UnknownProvider,
    InvalidOAuthState,
    UserNotAllowed,
    InvalidIdToken,
};

gpa: Allocator,
io: Io,
providers: []const config.OAuthProvider,
public_url: []const u8,
pending: Pending,
mutex: Io.Mutex = .init,
states: []ProviderState,

pub fn init(
    gpa: Allocator,
    io: Io,
    providers: []const config.OAuthProvider,
    public_url: []const u8,
) !OAuth {
    const states = try gpa.alloc(ProviderState, providers.len);
    @memset(states, .{});
    return .{
        .gpa = gpa,
        .io = io,
        .providers = providers,
        .public_url = public_url,
        .pending = .init(gpa, io),
        .states = states,
    };
}

pub fn deinit(self: *OAuth) void {
    for (self.states) |*state| {
        if (state.discovery) |*d| d.deinit();
        if (state.keys) |*k| k.deinit();
    }
    self.gpa.free(self.states);
    self.pending.deinit();
}

pub const Start = struct {
    /// Where to send the browser.
    url: []const u8,
    /// To be stored in the browser-binding cookie.
    state: Pending.Secret,
};

pub fn start(self: *OAuth, arena: Allocator, name: []const u8) !Start {
    const index = self.find(name) orelse return error.UnknownProvider;
    const provider = self.providers[index];
    const verifier = try Pending.randomSecret(self.io);
    const nonce = try Pending.randomSecret(self.io);
    const state = try self.pending.begin(.{
        .provider = index,
        .verifier = verifier,
        .nonce = nonce,
        .expires_s = 0,
    });
    const endpoint = try self.authorizationEndpoint(index);
    const challenge = pkceChallenge(&verifier);
    const redirect_uri = try self.redirectUri(arena, provider);
    const is_github = provider.kind == .github;
    const pairs = [_][2][]const u8{
        .{ "response_type", "code" },
        .{ "client_id", provider.client_id },
        .{ "redirect_uri", redirect_uri },
        .{ "scope", if (is_github) github.scope else "openid email" },
        .{ "state", &state },
        .{ "nonce", &nonce },
        .{ "code_challenge", &challenge },
        .{ "code_challenge_method", "S256" },
    };
    const query = try fetch.encodeForm(arena, &pairs);
    const separator: []const u8 =
        if (std.mem.indexOfScalar(u8, endpoint, '?') == null) "?" else "&";
    const url = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{
        endpoint, separator, query,
    });
    return .{ .url = url, .state = state };
}

/// Completes a login. `cookie_state` is the value of the cookie set
/// by `start`; it must equal `state`, which proves this browser
/// started this login (no login CSRF).
pub fn finish(
    self: *OAuth,
    arena: Allocator,
    name: []const u8,
    code: []const u8,
    state: []const u8,
    cookie_state: []const u8,
) !Identity {
    const index = self.find(name) orelse return error.UnknownProvider;
    if (state.len == 0 or !std.mem.eql(u8, state, cookie_state)) {
        return error.InvalidOAuthState;
    }
    const entry = self.pending.take(state) orelse
        return error.InvalidOAuthState;
    if (entry.provider != index) return error.InvalidOAuthState;

    const provider = self.providers[index];
    const form = try fetch.encodeForm(arena, &.{
        .{ "grant_type", "authorization_code" },
        .{ "code", code },
        .{ "redirect_uri", try self.redirectUri(arena, provider) },
        .{ "client_id", provider.client_id },
        .{ "client_secret", provider.client_secret },
        .{ "code_verifier", &entry.verifier },
    });
    const who = switch (provider.kind) {
        .github => try github.identify(self.gpa, self.io, arena, form),
        .google, .oidc => try self.oidcIdentity(
            arena,
            index,
            form,
            &entry.nonce,
        ),
    };
    if (!identity_mod.isAllowed(provider, who)) return error.UserNotAllowed;
    return who;
}

fn oidcIdentity(
    self: *OAuth,
    arena: Allocator,
    index: usize,
    form: []const u8,
    nonce: []const u8,
) !Identity {
    const provider = self.providers[index];
    const token_endpoint = try self.tokenEndpoint(arena, index);
    const raw = try oidc.exchangeCode(
        self.gpa,
        self.io,
        arena,
        token_endpoint,
        form,
    );
    const token = try jwt.decode(arena, raw);
    try self.verifySignature(arena, index, token);
    return oidc.checkClaims(arena, token.claims_json, .{
        .issuer = provider.issuerUrl(),
        .client_id = provider.client_id,
        .nonce = nonce,
        .now_s = Io.Timestamp.now(self.io, .real).toSeconds(),
    });
}

pub fn find(self: *const OAuth, name: []const u8) ?usize {
    for (self.providers, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, name)) return i;
    }
    return null;
}

pub fn redirectUri(
    self: *const OAuth,
    arena: Allocator,
    provider: config.OAuthProvider,
) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/api/v1/auth/oauth/{s}/callback", .{
        self.public_url, provider.name,
    });
}

/// base64url(SHA-256(verifier)), per RFC 7636 S256.
fn pkceChallenge(verifier: []const u8) [43]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(verifier, &digest, .{});
    var out: [43]u8 = undefined;
    _ = jwt.base64url.Encoder.encode(&out, &digest);
    return out;
}

// ------------------------------------------------------------------
// cached discovery and keys
// ------------------------------------------------------------------

/// Returned slices live as long as the discovery cache (process).
fn authorizationEndpoint(self: *OAuth, index: usize) ![]const u8 {
    if (self.providers[index].kind == .github) {
        return github.authorize_endpoint;
    }
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return (try self.discovery(index)).authorization_endpoint;
}

fn tokenEndpoint(self: *OAuth, arena: Allocator, index: usize) ![]const u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return arena.dupe(u8, (try self.discovery(index)).token_endpoint);
}

/// Caller holds `mutex`.
fn discovery(self: *OAuth, index: usize) !*oidc.Discovery {
    const state = &self.states[index];
    if (state.discovery == null) {
        const issuer = self.providers[index].issuerUrl();
        state.discovery = try oidc.discover(self.gpa, self.io, issuer);
    }
    return &state.discovery.?;
}

/// Verifies under the lock, so a concurrent key refresh cannot free
/// the key while it is in use.
fn verifySignature(
    self: *OAuth,
    arena: Allocator,
    index: usize,
    token: jwt.Token,
) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const state = &self.states[index];
    const now = Io.Timestamp.now(self.io, .real).toSeconds();
    const stale = now - state.keys_fetched_s > keys_ttl_s;
    const known = if (state.keys) |*k| k.find(token.kid) != null else false;
    if ((stale or !known) and
        now - state.keys_attempted_s >= min_refresh_interval_s)
    {
        state.keys_attempted_s = now;
        self.refreshKeys(arena, index) catch |err| {
            std.log.warn("oauth: fetching signing keys failed: {t}", .{err});
        };
    }
    const keys = &(state.keys orelse return error.InvalidIdToken);
    const key = keys.find(token.kid) orelse return error.InvalidIdToken;
    jwt.verify(token, key) catch return error.InvalidIdToken;
}

/// Caller holds `mutex`.
fn refreshKeys(self: *OAuth, arena: Allocator, index: usize) !void {
    const jwks_uri = (try self.discovery(index)).jwks_uri;
    const body = try fetch.json(self.gpa, self.io, arena, .{ .url = jwks_uri });
    const fresh = try jwt.KeySet.parse(self.gpa, body);
    const state = &self.states[index];
    if (state.keys) |*old| old.deinit();
    state.keys = fresh;
    state.keys_fetched_s = Io.Timestamp.now(self.io, .real).toSeconds();
}

test "pkce challenge is base64url(sha256(verifier))" {
    // Expected value cross-checked with Python's hashlib + base64.
    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWMIEjXk";
    const challenge = pkceChallenge(verifier);
    try std.testing.expectEqualStrings(
        "r-KoI2g1Doohapccaw169PAj-ocXuopWOsXLryLPD8A",
        &challenge,
    );
}
