const std = @import("std");
const mango = @import("root.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var client = mango.Client.init(allocator, mango.ConnectionOptions{ .user = "local", .pass = "8hwSYHJ1YDU5MIRwqnAVaXFSbimKFceW" });
    defer client.deinit();

    var conn = try client.connect("0.0.0.0:33645");
    try conn.ping();
    try conn.publish("hello.world", "hey from mango.zig");
    try conn.ping();
    try conn.ping();
    try conn.ping();
    try conn.ping();
    var sub = try conn.subscribe("hello", "world");
    try sub.call(msgCallback);
}

fn msgCallback(msg: mango.ServerMsg) void {
    std.debug.print("Received message: {s}\n", .{msg.payload.?});
}
