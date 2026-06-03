test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("ansi.zig");
    _ = @import("transcript.zig");
    _ = @import("markdown.zig");
    _ = @import("links.zig");
    _ = @import("render.zig");
    _ = @import("render_plain.zig");
}
