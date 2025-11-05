const std = @import("std");
const mango = @import("mango");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var client = mango.Client.init(allocator, mango.ConnectionOptions{ .user = "local", .pass = "8hwSYHJ1YDU5MIRwqnAVaXFSbimKFceW" });
    defer client.deinit();

    var conn = try client.connect("0.0.0.0:4222");
    try conn.ping();
    try conn.publish("hello.world", "connected from mango.zig");
    try conn.ping();
    var sub = try conn.subscribe("hello.world", "world");
    try sub.call(msgCallback, conn);
}

fn msgCallback(msg: mango.ServerMsg, conn: ?mango.Connection) !void {
    std.debug.print("Received message: {s}\n", .{msg.payload.?});
    var connection = conn.?;
    const str = try std.mem.concat(conn.?.allocator, u8, &[_][]const u8{ msg.payload.?, "\r\nechoed from mango.zig" });
    try connection.publish("hello.world", str);
}
