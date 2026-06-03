test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("ansi.zig");
}
