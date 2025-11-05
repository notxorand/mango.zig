const std = @import("std");
const root = @import("root.zig");

/// Client subscription.
pub const Subscription = struct {
    sid: u64,
    subject: []const u8,
    queue: []const u8,
    stream: std.net.Stream,
    allocator: std.mem.Allocator,

    const CallbackFn = fn (root.ServerMsg, ?root.Connection) anyerror!void;

    pub fn init(sid: u64, allocator: std.mem.Allocator, stream: std.net.Stream, subject: []const u8) Subscription {
        return Subscription{ .sid = sid, .subject = subject, .queue = "", .allocator = allocator, .stream = stream };
    }

    pub fn deinit(self: *Subscription) void {
        self.* = undefined;
    }

    /// Call a callback function for each message received on the subscription.
    ///
    /// Note: This currently polls as async was removed in zig v0.15.1. Io async is coming in v0.16.0.
    pub fn call(self: *Subscription, callback: CallbackFn, connection: ?root.Connection) !void {
        // TODO: async when v0.16.0 is released
        // var io_impl: std.Io.Threaded = .init(self.allocator);
        // defer io_impl.deinit();
        // const io = io_impl.io();
        // const read_task = try std.io.async(readAndCallback, .{self, callback, connection});
        // defer read_task.cancel();

        // try read_task.await(io);
        try self.readAndCallback(callback, connection);
    }

    fn readAndCallback(self: *Subscription, callback: CallbackFn, connection: ?root.Connection) !void {
        const ops = try root.readMsg(self.allocator, self.stream);

        const msg = try root.parseServerMsg(ops);
        try callback(msg, connection);
        try self.readAndCallback(callback, connection);
    }

    /// Poll for the next message received on the subscription.
    pub fn next(self: *Subscription) !root.ServerMsg {
        const ops = try root.readMsg(self.allocator, self.stream);

        return try root.parseServerMsg(ops);
    }
};
