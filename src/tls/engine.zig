//! The only file that touches the TLS library (ianic/tls.zig, TLS 1.3
//! server). To swap libraries, reimplement `Identity` and `Session`
//! here; the HTTP server only sees `Io.Reader` / `Io.Writer`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const lib = @import("tls");

/// Buffer sizes the underlying socket reader and writer need: a full
/// ciphertext record must fit.
pub const input_buffer_len = lib.input_buffer_len;
pub const output_buffer_len = lib.output_buffer_len;

/// True when the client opened with a TLS handshake record. Lets the
/// server drop plain-HTTP clients at once instead of waiting for a
/// record that never comes.
pub fn startsWithHandshake(input: *Io.Reader) bool {
    const handshake_record = 0x16;
    const first = input.peekByte() catch return false;
    return first == handshake_record;
}

/// The server's certificate chain and private key. Read-only once
/// loaded, so one instance serves every connection.
pub const Identity = struct {
    pair: lib.config.CertKeyPair,

    /// `cert_pem` may hold a chain, leaf first (e.g. fullchain.pem).
    pub fn fromPem(
        gpa: Allocator,
        io: Io,
        cert_pem: []const u8,
        key_pem: []const u8,
    ) !Identity {
        var pair = try lib.config.CertKeyPair.fromSlice(
            gpa,
            io,
            cert_pem,
            key_pem,
        );
        // Expired certificates are silently dropped while parsing.
        if (pair.bundle.map.count() == 0) {
            pair.deinit(gpa);
            return error.NoValidCertificate;
        }
        return .{ .pair = pair };
    }

    pub fn deinit(self: *Identity, gpa: Allocator) void {
        self.pair.deinit(gpa);
    }
};

/// One server-side TLS connection. Holds pointers into itself: create
/// it in place (`var s: Session = undefined;`) and never move it.
pub const Session = struct {
    conn: lib.Connection,
    reader: lib.Connection.Reader,
    writer: lib.Connection.Writer,

    /// Runs the handshake over the socket's `input` / `output`, then
    /// exposes cleartext through `reader` / `writer`, buffered by
    /// `cleartext_in` / `cleartext_out`.
    pub fn handshake(
        self: *Session,
        io: Io,
        identity: *Identity,
        input: *Io.Reader,
        output: *Io.Writer,
        cleartext_in: []u8,
        cleartext_out: []u8,
    ) !void {
        const rng_source: std.Random.IoSource = .{ .io = io };
        self.conn = try lib.server(input, output, .{
            .rng = rng_source.interface(),
            .auth = &identity.pair,
            .now = Io.Clock.real.now(io),
        });
        self.reader = self.conn.reader(cleartext_in);
        self.writer = self.conn.writer(cleartext_out);
    }

    /// Sends close_notify; best effort.
    pub fn close(self: *Session) void {
        self.conn.close() catch {};
    }
};
