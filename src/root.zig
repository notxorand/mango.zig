const std = @import("std");

pub const sub = @import("subscription.zig");
pub const Subscription = sub.Subscription;

/// Client to connect to a NATS server.
pub const Client = struct {
    allocator: std.mem.Allocator,
    options: ConnectionOptions,

    pub fn init(allocator: std.mem.Allocator, options: ConnectionOptions) Client {
        return Client{
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn connect(self: *Client, url: []const u8) !Connection {
        var connections: std.ArrayList(Connection) = .empty;
        defer connections.deinit(self.allocator);

        const stream = try newConnection(url);
        const server_info = try startHandshake(self.allocator, stream, self.options);
        return Connection.init(self.allocator, stream, self.options, server_info);
    }

    pub fn deinit(self: *Client) void {
        self.* = undefined;
    }
};

pub fn newConnection(url: []const u8) !std.net.Stream {
    const addr = try std.net.Address.parseIpAndPort(url);
    return try std.net.tcpConnectToAddress(addr);
}

/// Connection to a NATS server.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    subscriptions: std.AutoHashMap(u64, Subscription),
    next_sid: u64,
    connected: bool,
    server_info: ServerInfo,
    options: ConnectionOptions,

    pub fn init(allocator: std.mem.Allocator, stream: std.net.Stream, opts: ConnectionOptions, server_info: ServerInfo) Connection {
        return Connection{
            .allocator = allocator,
            .stream = stream,
            .subscriptions = std.AutoHashMap(u64, Subscription).init(allocator),
            .next_sid = 0,
            .connected = false,
            .server_info = server_info,
            .options = opts,
        };
    }

    /// Ping server for liveness.
    /// Returns an error if the server is not responding.
    pub fn ping(self: *Connection) !void {
        const msg = ClientOps.PING;
        const parsed = try parseClientOps(self.allocator, msg);
        try streamMsg(self.stream, parsed);
        const ops = try readMsg(self.allocator, self.stream);
        if (!std.mem.startsWith(u8, ops, "PONG")) {
            return error.ServerNotResponding;
        }
    }

    /// Publish a message to a subject.
    /// Returns an error if the server is not responding.
    pub fn publish(self: *Connection, subject: []const u8, payload: ?[]const u8) !void {
        const msg = ClientOps{ .PUB = .{ .subject = subject, .payload = payload } };
        const parsed = try parseClientOps(self.allocator, msg);
        defer self.allocator.free(parsed);
        try streamMsg(self.stream, parsed);

        const ops = try readMsg(self.allocator, self.stream);
        if (!std.mem.startsWith(u8, ops, "+OK")) {
            return error.ServerFailedToConnect;
        }
    }

    pub fn reply(self: *Connection, subject: []const u8, reply_to: []const u8, payload: ?[]const u8) !void {
        const msg = ClientOps{ .PUB = .{ .subject = subject, .reply_to = reply_to, .payload = payload } };
        const parsed = try parseClientOps(self.allocator, msg);
        defer self.allocator.free(parsed);
        try streamMsg(self.stream, parsed);
    }

    /// Subscribe to a subject.
    /// Returns a subscription object which can be polled for messages via `.next()` or `.call(callbackFn, ?conn)`.
    pub fn subscribe(self: *Connection, subject: []const u8, queue: ?[]const u8) !Subscription {
        const sid = try std.fmt.allocPrint(self.allocator, "{d}", .{self.next_sid});
        const msg = ClientOps{ .SUB = .{ .sid = sid, .subject = subject, .queue = queue } };
        const parsed = try parseClientOps(self.allocator, msg);
        defer self.allocator.free(parsed);
        try streamMsg(self.stream, parsed);

        const ops = try readMsg(self.allocator, self.stream);
        if (!std.mem.startsWith(u8, ops, "+OK")) {
            return error.ServerFailedToConnect;
        }
        const subscription = Subscription.init(self.next_sid, self.allocator, self.stream, subject);
        try self.subscriptions.put(subscription.sid, subscription);
        self.next_sid += 1;

        return subscription;
    }

    /// Unsubscribe from a subscription.
    pub fn unsubscribe(self: *Connection, subscription: Subscription) !void {
        const removed = self.subscriptions.remove(subscription.sid);
        if (!removed) {
            return error.SubscriptionNotFound;
        }

        const sid = try std.fmt.allocPrint(self.allocator, "{d}", .{subscription.sid});
        const msg = ClientOps{ .UNSUB = .{ .sid = sid } };
        const parsed = try parseClientOps(self.allocator, msg);
        defer self.allocator.free(parsed);
        try streamMsg(self.stream, parsed);
        const ops = try readMsg(self.allocator, self.stream);
        if (!std.mem.startsWith(u8, ops, "+OK")) {
            return error.ServerFailedToConnect;
        }
    }
};

/// Client connection options.
pub const ConnectionOptions = struct {
    verbose: bool = true,
    pedantic: bool = true,
    tls_required: bool = false,
    auth_token: ?[]const u8 = null,
    user: ?[]const u8 = null,
    pass: ?[]const u8 = null,
    name: ?[]const u8 = null,
    lang: []const u8 = "zig",
    version: []const u8 = "0.15.1",
    protocol: ?i32 = null,
    echo: ?bool = null,
    sig: ?[]const u8 = null,
    jwt: ?[]const u8 = null,
    no_responders: ?bool = null,
    headers: ?bool = null,
    nkey: []const u8 = "",
};

/// NATS protocol messages. Client.
///
/// See: https://docs.nats.io/reference/reference-protocols/nats-protocol#protocol-messages
/// TODO: include HPUB
pub const ClientOps = union(enum) {
    CONNECT: ConnectionOptions,
    PUB: struct {
        subject: []const u8 = "",
        reply_to: ?[]const u8 = null,
        payload: ?[]const u8 = null,
    },
    SUB: struct {
        sid: []const u8 = "",
        subject: []const u8 = "",
        queue: ?[]const u8 = null,
    },
    UNSUB: struct {
        sid: []const u8 = "",
        max: ?u64 = null,
    },
    PING,
    PONG,
};

fn parseClientOps(allocator: std.mem.Allocator, message: ClientOps) ![]const u8 {
    switch (message) {
        .CONNECT => |info| {
            var alloc = std.Io.Writer.Allocating.init(allocator);
            defer alloc.deinit();
            try alloc.writer.writeAll("CONNECT ");
            var stringify = std.json.Stringify{
                .writer = &alloc.writer,
                .options = .{
                    .emit_null_optional_fields = false,
                },
            };
            try stringify.write(info);
            try alloc.writer.writeAll("\r\n");

            return try alloc.toOwnedSlice();
        },
        .PUB => |publish| {
            var array_list: std.ArrayList(u8) = .empty;
            defer array_list.deinit(allocator);

            const writer = array_list.writer(allocator);
            try writer.print("PUB {s}", .{publish.subject});
            if (publish.reply_to) |reply_to| {
                try writer.print(" {s}", .{reply_to});
            }
            if (publish.payload) |payload| {
                try writer.print(" {d}", .{payload.len});
                try writer.print("\r\n{s}", .{payload});
            } else {
                try writer.print(" {d}", .{0});
            }
            try writer.writeAll("\r\n");

            return try array_list.toOwnedSlice(allocator);
        },
        .SUB => |subscribe| {
            var array_list: std.ArrayList(u8) = .empty;
            defer array_list.deinit(allocator);

            const writer = array_list.writer(allocator);
            try writer.print("SUB {s}", .{subscribe.subject});
            if (subscribe.queue) |queue| {
                try writer.print(" {s}", .{queue});
            }
            try writer.print(" {s}", .{subscribe.sid});
            try writer.writeAll("\r\n");

            return try array_list.toOwnedSlice(allocator);
        },
        .UNSUB => |unsubscribe| {
            return std.fmt.allocPrint(allocator, "UNSUB {s} {any}\r\n", .{ unsubscribe.sid, unsubscribe.max orelse null });
        },
        .PING => {
            return "PING\r\n";
        },
        .PONG => {
            return "PONG\r\n";
        },
    }
}

/// Connected server info.
pub const ServerInfo = struct {
    server_id: []const u8 = "",
    server_name: []const u8 = "",
    version: []const u8 = "",
    go: []const u8 = "",
    host: []const u8 = "",
    port: u16 = 0,
    headers: bool = false,
    max_payload: u64 = 0,
    proto: i32 = 0,
    client_id: ?u64 = null,
    auth_required: ?bool = null,
    tls_required: ?bool = null,
    tls_verify: ?bool = null,
    tls_available: ?bool = null,
    connect_urls: ?[]const []const u8 = null,
    ws_connect_urls: ?[]const []const u8 = null,
    ldm: ?bool = null,
    git_commit: ?[]const u8 = null,
    jetstream: ?bool = null,
    ip: ?[]const u8 = null,
    client_ip: ?[]const u8 = null,
    nonce: ?[]const u8 = null,
    cluster: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    xkey: ?[]const u8 = null,
};

/// Server message.
pub const ServerMsg = struct {
    subject: []const u8 = "",
    sid: []const u8 = "",
    reply_to: ?[]const u8 = null,
    bytes: i32 = 0,
    payload: ?[]const u8 = null,
};

/// NATS protocol messages. Server.
///
/// See: https://docs.nats.io/reference/reference-protocols/nats-protocol#protocol-messages
/// TODO: handle HMSG
pub const ServerOps = union(enum) {
    INFO: ServerInfo,
    MSG: ServerMsg,
    PING,
    PONG,
    OK,
    ERROR: ServerError,
};

fn parseServerOps(allocator: std.mem.Allocator, ops: []const u8) !ServerOps {
    if (std.mem.startsWith(u8, ops, "INFO")) {
        const parse_info = try parseServerInfo(allocator, ops);
        defer parse_info.deinit();
        const info = parse_info.value;
        return .{ .INFO = info };
    }
    if (std.mem.startsWith(u8, ops, "MSG")) return .{ .MSG = try parseServerMsg(ops) };
    if (std.mem.startsWith(u8, ops, "PING")) return ServerOps.PING;
    if (std.mem.startsWith(u8, ops, "PONG")) return ServerOps.PONG;
    if (std.mem.startsWith(u8, ops, "+OK")) return ServerOps.OK;
    if (std.mem.startsWith(u8, ops, "-ERROR")) return .{ .ERROR = try parseServerError(ops) };

    return error.UnknownOp;
}

fn parseServerInfo(allocator: std.mem.Allocator, ops: []const u8) !std.json.Parsed(ServerInfo) {
    const index = std.mem.indexOf(u8, ops, " ").?;
    const json_start = index + 1;
    const json_end = std.mem.indexOf(u8, ops[json_start..], "\r\n") orelse ops.len - json_start;
    const json_str = ops[json_start..][0..json_end];
    return try std.json.parseFromSlice(ServerInfo, allocator, json_str, .{});
}

pub fn parseServerMsg(ops: []const u8) !ServerMsg {
    const line_end = std.mem.indexOf(u8, ops, "\r\n").?;
    const line = ops[0..line_end];
    var iter = std.mem.splitScalar(u8, line, ' ');

    _ = iter.next().?;

    const subject = iter.next().?;
    const sid = iter.next().?;

    const third = iter.next().?;
    const fourth = iter.next();
    var reply_to: ?[]const u8 = null;
    var bytes_str: []const u8 = undefined;
    if (fourth) |b| {
        reply_to = third;
        bytes_str = b;
    } else {
        bytes_str = third;
    }
    const bytes = try std.fmt.parseInt(usize, bytes_str, 10);

    var payload: ?[]const u8 = null;
    if (bytes > 0 and ops.len > line_end + 2) {
        const payload_start = line_end + 2;
        if (payload_start + bytes <= ops.len) {
            payload = ops[payload_start..][0..bytes];
        }
    }

    return ServerMsg{
        .subject = subject,
        .sid = sid,
        .reply_to = reply_to,
        .bytes = @intCast(bytes),
        .payload = payload,
    };
}

/// NATS protocol errors.
///
/// See: https://docs.nats.io/reference/reference-protocols/nats-protocol#ok-err
pub const ServerError = enum {
    // Connection invalid, clean-up client
    UNKNOWN_PROTOCOL_OPERATION,
    ATTEMPTED_TO_CONNECT_TO_ROUTE_PORT,
    AUTHORIZATION_VIOLATION,
    AUTHORIZATION_TIMEOUT,
    INVALID_CLIENT_PROTOCOL,
    MAXIMUM_CONTROL_LINE_EXCEEDED,
    PARSER_ERROR,
    SECURE_CONNECTION_TLS_REQUIRED,
    STALE_CONNECTION,
    MAXIMUM_CONNECTIONS_EXCEEDED,
    SLOW_CONSUMER,
    MAXIMUM_PAYLOAD_VIOLATION,
    // Keep connection open
    INVALID_SUBJECT,
    PERMISSIONS_VIOLATION_FOR_SUBSCRIPTION_TO_SUBJECT,
    PERMISSIONS_VIOLATION_FOR_PUBLISH_TO_SUBJECT,
    // Edge case
    UNKNOWN_ERROR,
};

fn parseServerError(err: []const u8) !ServerError {
    const index = std.mem.indexOf(u8, err, " ").?;
    const err_start = index + 1;
    const err_end = std.mem.indexOf(u8, err[err_start..], "\r\n") orelse err.len - err_start;
    const dirty_str = err[err_start..][0..err_end];
    const err_str = if (std.mem.startsWith(u8, dirty_str, "'")) dirty_str[1 .. dirty_str.len - 1] else dirty_str;
    // use ServerError Enum
    if (std.mem.eql(u8, err_str, "Unknown Protocol Operation")) return ServerError.UNKNOWN_PROTOCOL_OPERATION;
    if (std.mem.eql(u8, err_str, "Attempted To Connect To Route Port")) return ServerError.ATTEMPTED_TO_CONNECT_TO_ROUTE_PORT;
    if (std.mem.eql(u8, err_str, "Authorization Violation")) return ServerError.AUTHORIZATION_VIOLATION;
    if (std.mem.eql(u8, err_str, "Authorization Timeout")) return ServerError.AUTHORIZATION_TIMEOUT;
    if (std.mem.eql(u8, err_str, "Invalid Client Protocol")) return ServerError.INVALID_CLIENT_PROTOCOL;
    if (std.mem.eql(u8, err_str, "Maximum Control Line Exceeded")) return ServerError.MAXIMUM_CONTROL_LINE_EXCEEDED;
    if (std.mem.eql(u8, err_str, "Parser Error")) return ServerError.PARSER_ERROR;
    if (std.mem.eql(u8, err_str, "Secure Connection TLS Required")) return ServerError.SECURE_CONNECTION_TLS_REQUIRED;
    if (std.mem.eql(u8, err_str, "Stale Connection")) return ServerError.STALE_CONNECTION;
    if (std.mem.eql(u8, err_str, "Maximum Connections Exceeded")) return ServerError.MAXIMUM_CONNECTIONS_EXCEEDED;
    if (std.mem.eql(u8, err_str, "Slow Consumer Detected")) return ServerError.SLOW_CONSUMER;
    if (std.mem.eql(u8, err_str, "Maximum Payload Exceeded")) return ServerError.MAXIMUM_PAYLOAD_VIOLATION;
    if (std.mem.eql(u8, err_str, "Invalid Subject")) return ServerError.INVALID_SUBJECT;
    if (std.mem.eql(u8, err_str, "Permissions Violation For Subscription To Subject")) return ServerError.PERMISSIONS_VIOLATION_FOR_SUBSCRIPTION_TO_SUBJECT;
    if (std.mem.eql(u8, err_str, "Permissions Violation For Publish To Subject")) return ServerError.PERMISSIONS_VIOLATION_FOR_PUBLISH_TO_SUBJECT;
    return ServerError.UNKNOWN_ERROR;
}

fn streamMsg(stream: std.net.Stream, payload: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = stream.writer(buffer[0..]);
    try writer.interface.writeAll(payload);
    try writer.interface.flush();
}

fn pong(allocator: std.mem.Allocator, stream: std.net.Stream) !void {
    const msg = ClientOps.PONG;
    const parsed = try parseClientOps(allocator, msg);
    try streamMsg(stream, parsed);
}

pub fn readMsg(allocator: std.mem.Allocator, stream: std.net.Stream) ![]u8 {
    var buffer: [4096]u8 = undefined;
    var reader = stream.reader(&buffer);
    const msg = try reader.interface().takeDelimiterInclusive('\n');
    if (std.mem.startsWith(u8, msg, "PING")) {
        try pong(allocator, stream);
        return try readMsg(allocator, stream);
    } else if (std.mem.startsWith(u8, msg, "MSG")) {
        const payload = try reader.interface().takeDelimiterInclusive('\n');
        return try std.mem.concat(allocator, u8, &[_][]const u8{ msg, payload });
    } else if (std.mem.startsWith(u8, msg, "HMSG")) {
        return error.MessageNotImplemented;
    }

    return try allocator.dupe(u8, msg);
}

fn startHandshake(allocator: std.mem.Allocator, stream: std.net.Stream, opts: ConnectionOptions) !ServerInfo {
    const ops = try readMsg(allocator, stream);
    if (!std.mem.startsWith(u8, ops, "INFO")) {
        return error.ServerTooEager;
    }

    const msg = ClientOps{ .CONNECT = opts };
    try streamMsg(stream, try parseClientOps(allocator, msg));

    const info = try parseServerInfo(allocator, ops);
    defer info.deinit();

    const ops2 = try readMsg(allocator, stream);
    if (!std.mem.startsWith(u8, ops2, "+OK")) {
        return error.ServerFailedToConnect;
    }
    return info.value;
}

test "parse client ops" {
    const allocator = std.testing.allocator;

    const msg = ClientOps{ .SUB = .{ .sid = "1234", .subject = "FOO", .queue = "G1" } };
    const parsed = try parseClientOps(allocator, msg);
    defer allocator.free(parsed);

    try std.testing.expectEqualStrings("SUB FOO G1 1234\r\n", parsed);

    const msg2 = ClientOps{ .PUB = .{ .subject = "FOO", .reply_to = null, .payload = null } };
    const parsed2 = try parseClientOps(allocator, msg2);
    defer allocator.free(parsed2);

    try std.testing.expectEqualStrings("PUB FOO 0\r\n", parsed2);

    const msg3 = ClientOps{ .PUB = .{ .subject = "FOO", .reply_to = null, .payload = "Hello, World!" } };
    const parsed3 = try parseClientOps(allocator, msg3);
    defer allocator.free(parsed3);

    try std.testing.expectEqualStrings("PUB FOO 13\r\nHello, World!\r\n", parsed3);

    const msg4 = ClientOps{ .CONNECT = .{
        .verbose = false,
        .pedantic = false,
        .tls_required = false,
        .lang = "zig",
        .version = "0.15.1",
        .protocol = 1,
        .nkey = "",
    } };

    const parsed4 = try parseClientOps(allocator, msg4);
    defer allocator.free(parsed4);

    try std.testing.expectEqualStrings("CONNECT {\"verbose\":false,\"pedantic\":false,\"tls_required\":false,\"lang\":\"zig\",\"version\":\"0.15.1\",\"protocol\":1,\"nkey\":\"\"}\r\n", parsed4);
}

test "parse server info" {
    const allocator = std.testing.allocator;

    const info_str = "INFO {\"server_id\":\"1234567890\",\"server_name\":\"test\",\"version\":\"2.0.0\",\"go\":\"go1.18\",\"host\":\"127.0.0.1\",\"port\":4222,\"headers\":true,\"max_payload\":1048576,\"proto\":1}\r\n";

    const parse_info = try parseServerInfo(allocator, info_str);
    defer parse_info.deinit();
    const info = parse_info.value;

    try std.testing.expectEqualStrings(info.server_id, "1234567890");
    try std.testing.expectEqualStrings(info.version, "2.0.0");
    try std.testing.expectEqualStrings(info.go, "go1.18");
    try std.testing.expectEqualStrings(info.host, "127.0.0.1");
    try std.testing.expectEqual(info.port, 4222);
    try std.testing.expectEqual(info.max_payload, 1048576);
}

test "parse server msg without reply" {
    const msg = "MSG FOO.BAR 9 11\r\nHello World\r\n";
    const parsed = try parseServerMsg(msg);

    try std.testing.expectEqualStrings("FOO.BAR", parsed.subject);
    try std.testing.expectEqualStrings("9", parsed.sid);
    try std.testing.expect(parsed.reply_to == null);
    try std.testing.expectEqual(@as(i32, 11), parsed.bytes);
    try std.testing.expectEqualStrings("Hello World", parsed.payload.?);
}

test "parse server msg with reply" {
    const msg = "MSG FOO.BAR 9 INBOX.34 11\r\nHello World\r\n";
    const parsed = try parseServerMsg(msg);

    try std.testing.expectEqualStrings("FOO.BAR", parsed.subject);
    try std.testing.expectEqualStrings("9", parsed.sid);
    try std.testing.expectEqualStrings("INBOX.34", parsed.reply_to.?);
    try std.testing.expectEqual(@as(i32, 11), parsed.bytes);
    try std.testing.expectEqualStrings("Hello World", parsed.payload.?);
}

test "parse server error" {
    const err = "-ERR Invalid Subject\r\n";
    const parsed = try parseServerError(err);

    try std.testing.expectEqual(ServerError.INVALID_SUBJECT, parsed);
}

test "parse server msg with ops" {
    const allocator = std.testing.allocator;

    const msg = "MSG FOO.BAR 9 INBOX.34 11\r\nHello World\r\n";
    const parsed = try parseServerOps(allocator, msg);

    try std.testing.expectEqual(ServerOps.MSG == parsed, true);

    const msg2 = "PING\r\n";
    const parsed2 = try parseServerOps(allocator, msg2);

    try std.testing.expectEqual(ServerOps.PING, parsed2);

    const msg3 = "+OK\r\n";
    const parsed3 = try parseServerOps(allocator, msg3);

    try std.testing.expectEqual(ServerOps.OK, parsed3);
}
