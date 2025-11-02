const std = @import("std");

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
