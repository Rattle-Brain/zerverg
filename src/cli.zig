//! Command-line parsing. Produces a `Command`; executes nothing.

const std = @import("std");

pub const usage =
    \\Usage: zerverg <command> [options]
    \\
    \\Commands:
    \\  serve            Run the web server
    \\  hash-password    Read a password from stdin, print its hash
    \\  help             Show this message
    \\
    \\Serve options:
    \\  --config <path>  Config file (default /etc/zerverg/zerverg.zon)
    \\  --data <dir>     Data directory (overrides config)
    \\  --listen <addr>  Listen address (overrides config)
    \\  --port <port>    HTTP port (overrides config)
    \\  --dev            Development mode: NO AUTH, binds 127.0.0.1
    \\
;

pub const ServeOptions = struct {
    config_path: ?[]const u8 = null,
    data_dir: ?[]const u8 = null,
    listen_address: ?[]const u8 = null,
    port: ?u16 = null,
    dev: bool = false,
};

pub const Command = union(enum) {
    serve: ServeOptions,
    hash_password,
    help,
};

pub const ParseError = error{
    UnknownCommand,
    UnknownOption,
    MissingValue,
    InvalidPort,
};

/// `args` excludes the program name.
pub fn parse(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return .help;
    const name = args[0];
    if (eql(name, "serve")) return .{ .serve = try parseServe(args[1..]) };
    if (eql(name, "hash-password")) return .hash_password;
    if (eql(name, "help") or eql(name, "--help")) return .help;
    return error.UnknownCommand;
}

fn parseServe(args: []const []const u8) ParseError!ServeOptions {
    var options: ServeOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        if (eql(flag, "--dev")) {
            options.dev = true;
            continue;
        }
        if (i + 1 >= args.len) return error.MissingValue;
        i += 1;
        const value = args[i];
        if (eql(flag, "--config")) {
            options.config_path = value;
        } else if (eql(flag, "--data")) {
            options.data_dir = value;
        } else if (eql(flag, "--listen")) {
            options.listen_address = value;
        } else if (eql(flag, "--port")) {
            options.port = std.fmt.parseInt(u16, value, 10) catch
                return error.InvalidPort;
        } else {
            return error.UnknownOption;
        }
    }
    return options;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "parse serve with flags" {
    const cmd = try parse(&.{ "serve", "--dev", "--port", "8000" });
    try std.testing.expect(cmd.serve.dev);
    try std.testing.expectEqual(@as(?u16, 8000), cmd.serve.port);
}

test "parse rejects unknown option" {
    try std.testing.expectError(
        error.UnknownOption,
        parse(&.{ "serve", "--nope", "x" }),
    );
}
