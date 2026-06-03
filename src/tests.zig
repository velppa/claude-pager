test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("ansi.zig");
    _ = @import("transcript.zig");
    _ = @import("markdown.zig");
}
