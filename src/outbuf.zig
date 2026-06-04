// outbuf.zig — growable output byte buffer for the drawing code.
// Mirrors the C ob/obf pattern in bin/pager.c:560-617 but backed by a
// heap-allocated ArrayList so callers never have to worry about overflow.

const std = @import("std");

pub const OutBuf = struct {
    list: std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,

    pub fn init(a: std.mem.Allocator) OutBuf {
        return .{
            .list = .empty,
            .alloc = a,
        };
    }

    pub fn deinit(self: *OutBuf) void {
        self.list.deinit(self.alloc);
    }

    /// Append a raw byte slice.
    pub fn write(self: *OutBuf, s: []const u8) !void {
        try self.list.appendSlice(self.alloc, s);
    }

    /// Append a formatted string (allocating as needed).
    pub fn print(self: *OutBuf, comptime fmt: []const u8, args: anytype) !void {
        try self.list.print(self.alloc, fmt, args);
    }

    /// Return the current contents (valid until the next write/print/clear).
    pub fn bytes(self: *OutBuf) []const u8 {
        return self.list.items;
    }

    /// Reset length to 0 without freeing capacity.
    pub fn clear(self: *OutBuf) void {
        self.list.clearRetainingCapacity();
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "outbuf write and print accumulate" {
    var b = OutBuf.init(std.testing.allocator);
    defer b.deinit();
    try b.write("ab");
    try b.print("{d}", .{12});
    try std.testing.expectEqualStrings("ab12", b.bytes());
}

test "outbuf clear resets" {
    var b = OutBuf.init(std.testing.allocator);
    defer b.deinit();
    try b.write("xyz");
    b.clear();
    try std.testing.expectEqual(@as(usize, 0), b.bytes().len);
}
