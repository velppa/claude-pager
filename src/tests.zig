test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("ansi.zig");
    _ = @import("transcript.zig");
    _ = @import("markdown.zig");
    _ = @import("links.zig");
    _ = @import("render.zig");
    _ = @import("render_plain.zig");
    _ = @import("outbuf.zig");
    _ = @import("log.zig");
    _ = @import("term.zig");
    _ = @import("input.zig");
    _ = @import("queue_persist.zig");
    _ = @import("queue_clipboard.zig");
}
