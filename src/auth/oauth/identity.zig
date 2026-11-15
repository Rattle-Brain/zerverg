//! Who a provider says the user is, and whether they may come in.

const std = @import("std");

const OAuthProvider = @import("../../config.zig").OAuthProvider;

pub const Identity = struct {
    /// OIDC `sub`, or GitHub's numeric user id: stable, never reused.
    subject: []const u8,
    email: []const u8 = "",
    email_verified: bool = false,
    /// GitHub login name (can be renamed, then claimed by others).
    login: []const u8 = "",

    /// The name shown in the console and the audit log.
    pub fn displayName(self: Identity) []const u8 {
        if (self.login.len > 0) return self.login;
        if (self.email.len > 0) return self.email;
        return self.subject;
    }
};

/// Allowlist entries:
///   "sub:<subject>"  OIDC subject          (google, oidc)
///   "id:<number>"    GitHub numeric id     (github, recommended)
///   "<e-mail>"       verified e-mail only  (google, oidc)
///   "<login>"        GitHub login name     (github)
pub fn isAllowed(provider: OAuthProvider, identity: Identity) bool {
    for (provider.allowed_users) |entry| {
        if (matches(provider, identity, entry)) return true;
    }
    return false;
}

fn matches(
    provider: OAuthProvider,
    identity: Identity,
    entry: []const u8,
) bool {
    const sub_prefix = "sub:";
    const id_prefix = "id:";
    switch (provider.kind) {
        .github => {
            if (std.mem.startsWith(u8, entry, id_prefix)) {
                return eql(entry[id_prefix.len..], identity.subject);
            }
            return std.ascii.eqlIgnoreCase(entry, identity.login);
        },
        .google, .oidc => {
            if (std.mem.startsWith(u8, entry, sub_prefix)) {
                return eql(entry[sub_prefix.len..], identity.subject);
            }
            // An unverified address proves nothing: anyone can type one.
            return identity.email_verified and identity.email.len > 0 and
                std.ascii.eqlIgnoreCase(entry, identity.email);
        },
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return a.len > 0 and std.mem.eql(u8, a, b);
}

test "allowlist rules" {
    const google: OAuthProvider = .{
        .name = "google",
        .kind = .google,
        .client_id = "x",
        .allowed_users = &.{ "me@x.test", "sub:777" },
    };
    try std.testing.expect(isAllowed(google, .{
        .subject = "1",
        .email = "ME@x.test",
        .email_verified = true,
    }));
    try std.testing.expect(!isAllowed(google, .{
        .subject = "1",
        .email = "me@x.test",
        .email_verified = false,
    }));
    try std.testing.expect(isAllowed(google, .{ .subject = "777" }));

    const github: OAuthProvider = .{
        .name = "github",
        .kind = .github,
        .client_id = "x",
        .allowed_users = &.{"id:583231"},
    };
    try std.testing.expect(isAllowed(github, .{
        .subject = "583231",
        .login = "renamed",
    }));
    try std.testing.expect(!isAllowed(github, .{
        .subject = "1",
        .login = "id:583231",
    }));
}
