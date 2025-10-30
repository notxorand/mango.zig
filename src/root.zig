const std = @import("std");

/// Client to connect to a NATS server.
pub const Client = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    next_sid: u64,
    subscriptions: std.HashMap(u64, Subscription, void, 16),
    write_buffer: std.ArrayList(u8),
    read_thread: ?std.Thread,
    connected: bool,
    server_info: ServerInfo,

    pub fn connect(allocator: std.mem.Allocator, stream: std.net.Stream) !Client {
        return Client{
            .allocator = allocator,
            .stream = stream,
            .next_sid = 0,
            .subscriptions = std.HashMap(u64, Subscription, void, 16).init(allocator),
            .write_buffer = std.ArrayList(u8).init(allocator),
            .read_thread = null,
            .connected = false,
            .server_info = ServerInfo{},
        };
    }

    pub fn disconnect(self: *Client) void {
        self.* = undefined;
    }

    pub fn subscribe(self: *Client, subject: []const u8) Subscription {
        self.next_sid += 1;
        return Subscription.init(self.next_sid, self.allocator, subject);
    }

    // TODO: do more than this
    pub fn unsubscribe(self: *Client, subscription: Subscription) void {
        self.subscriptions.remove(subscription.id);
    }
};

/// Client connection info.
pub const ConnectionInfo = struct {
    verbose: bool,
    pedantic: bool,
    tls_required: bool,
    auth_token: ?[]const u8,
    user: ?[]const u8,
    pass: ?[]const u8,
    name: ?[]const u8,
    lang: []const u8,
    version: []const u8,
    protocol: ?i32,
    echo: ?bool,
    sig: ?[]const u8,
    jwt: ?[]const u8,
    no_responders: ?bool,
    headers: ?bool,
    nkey: []const u8,
};

/// NATS protocol messages. Client.
///
/// See: https://docs.nats.io/reference/reference-protocols/nats-protocol#protocol-messages
pub const ClientOps = union(enum) {
    CONNECT: ConnectionInfo,
    PUB: struct {
        subject: []const u8,
        payload: []const u8,
        respond: ?[]const u8,
        headers: ?[]const u8,
    },
    SUB: struct {
        sid: []const u8,
        subject: []const u8,
        queue: ?[]const u8,
    },
    UNSUB: struct {
        sid: []const u8,
        max: ?u64,
    },
    PING,
    PONG,
};

/// Connected server info.
pub const ServerInfo = struct {
    server_id: []const u8,
    server_name: []const u8,
    version: []const u8,
    go: []const u8,
    host: []const u8,
    port: u16,
    headers: bool,
    max_payload: u64,
    proto: i32,
    client_id: ?u64,
    auth_required: ?bool,
    tls_required: ?bool,
    tls_verify: ?bool,
    tls_available: ?bool,
    connect_urls: ?[]const []const u8,
    ws_connect_urls: ?[]const []const u8,
    ldm: ?bool,
    git_commit: ?[]const u8,
    jetstream: ?bool,
    ip: ?[]const u8,
    client_ip: ?[]const u8,
    nonce: ?[]const u8,
    cluster: ?[]const u8,
    domain: ?[]const u8,
};

/// NATS protocol messages. Server.
///
/// See: https://docs.nats.io/reference/reference-protocols/nats-protocol#protocol-messages
pub const ServerOps = union(enum) {
    INFO: ServerInfo,
    MSG: struct {
        subject: []const u8,
        sid: []const u8,
        reply_to: []const u8,
        data: []const u8,
        headers: ?[]const u8,
    },
    PING,
    PONG,
    OK,
    ERROR,
};

/// NATS protocol errors.
///
/// See: https://docs.nats.io/reference/reference-protocols/nats-protocol#ok-err
pub const Error = error{
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

/// Client message.
pub const Message = struct {
    subject: []const u8,
    reply_to: []const u8,
    data: []const u8,
    subscription: Subscription,

    pub fn init(subject: []const u8, reply_to: []const u8, data: []const u8, subscription: Subscription) Message {
        return Message{ .subject = subject, .reply_to = reply_to, .data = data, .subscription = subscription };
    }
    pub fn deinit(self: *Message) void {
        self.* = undefined;
    }
};

/// Client subscription.
pub const Subscription = struct {
    sid: u64,
    subject: []const u8,
    queue: []const u8,
    messages: std.ArrayList(Message),

    pub fn init(sid: u64, allocator: std.mem.Allocator, subject: []const u8) Subscription {
        return Subscription{ .sid = sid, .subject = subject, .queue = "", .messages = std.ArrayList(Message).init(allocator) };
    }
    pub fn deinit(self: *Subscription) void {
        self.* = undefined;
    }
    pub fn next(self: *Subscription) ?Message {
        if (self.messages.items.len == 0) return null;
        return self.messages.pop();
    }
};
