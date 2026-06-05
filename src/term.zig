const std = @import("std");

pub const Winsize = struct {
    rows: u16,
    cols: u16,
    pub fn colsOr(self: Winsize, d: u16) u16 {
        return if (self.cols == 0) d else self.cols;
    }
    pub fn rowsOr(self: Winsize, d: u16) u16 {
        return if (self.rows == 0) d else self.rows;
    }
};

// Open /dev/tty read-write, returning a raw fd.
pub fn openTty() !std.posix.fd_t {
    return std.posix.openat(std.posix.AT.FDCWD, "/dev/tty", .{ .ACCMODE = .RDWR }, 0);
}

// Query terminal size via TIOCGWINSZ; returns {0,0} on failure (caller falls back).
pub fn getWinsize(fd: std.posix.fd_t) Winsize {
    var ws: std.posix.winsize = std.mem.zeroes(std.posix.winsize);
    const rc = std.c.ioctl(fd, std.c.T.IOCGWINSZ, &ws);
    if (rc != 0) return .{ .rows = 0, .cols = 0 };
    return .{ .rows = ws.row, .cols = ws.col };
}

pub const RawMode = struct {
    fd: std.posix.fd_t,
    orig: std.posix.termios,

    // Enter raw mode, saving the original termios. Restore with restore() (use defer).
    pub fn enable(fd: std.posix.fd_t) !RawMode {
        const orig = try std.posix.tcgetattr(fd);
        var t = orig;
        // c_iflag &= ~(IGNBRK|BRKINT|PARMRK|ISTRIP|INLCR|IGNCR|ICRNL|IXON|IXOFF)
        t.iflag.IGNBRK = false;
        t.iflag.BRKINT = false;
        t.iflag.PARMRK = false;
        t.iflag.ISTRIP = false;
        t.iflag.INLCR = false;
        t.iflag.IGNCR = false;
        t.iflag.ICRNL = false;
        t.iflag.IXON = false;
        t.iflag.IXOFF = false;
        // c_lflag &= ~(ICANON|ECHO|IEXTEN|ISIG)
        t.lflag.ICANON = false;
        t.lflag.ECHO = false;
        t.lflag.IEXTEN = false;
        t.lflag.ISIG = false;
        // c_cflag |= CS8
        t.cflag.CSIZE = .CS8;
        // c_cc[VMIN] = 0; c_cc[VTIME] = 0
        t.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        t.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(fd, .NOW, t);
        return .{ .fd = fd, .orig = orig };
    }

    pub fn restore(self: RawMode) void {
        std.posix.tcsetattr(self.fd, .NOW, self.orig) catch {};
    }
};

test "Winsize colsOr/rowsOr fallback" {
    const z = Winsize{ .rows = 0, .cols = 0 };
    try std.testing.expectEqual(@as(u16, 80), z.colsOr(80));
    try std.testing.expectEqual(@as(u16, 24), z.rowsOr(24));
    const w = Winsize{ .rows = 50, .cols = 200 };
    try std.testing.expectEqual(@as(u16, 200), w.colsOr(80));
    try std.testing.expectEqual(@as(u16, 50), w.rowsOr(24));
}

test "getWinsize on an invalid fd returns zeros" {
    const ws = getWinsize(-1);
    try std.testing.expectEqual(@as(u16, 0), ws.cols);
}
