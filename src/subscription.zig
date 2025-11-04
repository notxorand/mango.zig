const std = @import("std");
const root = @import("root.zig");

/// Client subscription.
pub const Subscription = struct {
    sid: u64,
    subject: []const u8,
    queue: []const u8,
    stream: std.net.Stream,
    allocator: std.mem.Allocator,

    const CallbackFn = fn (root.ServerMsg) void;

    pub fn init(sid: u64, allocator: std.mem.Allocator, stream: std.net.Stream, subject: []const u8) Subscription {
        return Subscription{ .sid = sid, .subject = subject, .queue = "", .allocator = allocator, .stream = stream };
    }

    pub fn deinit(self: *Subscription) void {
        self.* = undefined;
    }

    pub fn call(self: *Subscription, callback: CallbackFn) !void {
        const ops = try root.readMsg(self.allocator, self.stream);

        const msg = try root.parseServerMsg(ops);
        callback(msg);
        try self.call(callback);
    }

    pub fn next(self: *Subscription) !root.ServerMsg {
        const ops = try root.readMsg(self.allocator, self.stream);

        return try root.parseServerMsg(ops);
    }
};
