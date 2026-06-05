//! editor.zig — Editor-command validation and GUI/terminal-editor detection.
//!
//! Provides the following functions:
//!   isSelf            — detect the editor being claude-pager-open itself
//!   editorExists      — check the editor binary exists / is runnable
//!   basename          — extract the basename token of an editor command
//!   isKnownGuiEditor  — is it a known GUI editor
//!   isTerminalEditor  — is it a terminal (TUI) editor

const std = @import("std");

/// Terminal (TUI) editors — the list of editors that run inside the terminal.
const tui_editors = [_][]const u8{
    "vi",       "vim",      "nvim",     "lvim",    "nvi",
    "vim.basic","vim.tiny", "vim.nox",  "vim.gtk", "vim.gtk3",
    "emacs",    "nano",     "micro",
    "helix",    "hx",       "kakoune",  "kak",     "joe",
    "ed",       "ne",       "mg",       "jed",     "tilde",
    "dte",      "mcedit",   "amp",
};

/// GUI editors — the list of editors that open in a separate window.
const gui_editors = [_][]const u8{
    "open",   "code",      "cursor",   "zed",      "subl",
    "bbedit", "mate",      "idea",     "webstorm", "pycharm",
    "goland", "clion",     "rider",    "fleet",
};

// X_OK constant for access(2) — same value on macOS/Linux.
const X_OK: c_uint = 1;

/// getenv helper for Zig 0.16 — std.posix.getenv is gone, scan std.c.environ.
fn getEnv(name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const e = std.mem.span(entry);
        if (e.len > name.len and e[name.len] == '=' and
            std.mem.eql(u8, e[0..name.len], name))
        {
            return e[name.len + 1 ..];
        }
    }
    return null;
}

/// Extract the first whitespace-delimited token from `cmd` into `buf`.
/// Returns a slice into `buf`, or null if `cmd` is empty or buf is too small.
fn firstToken(cmd: []const u8, buf: []u8) ?[]u8 {
    // Skip leading whitespace.
    var start: usize = 0;
    while (start < cmd.len and (cmd[start] == ' ' or cmd[start] == '\t')) : (start += 1) {}
    if (start >= cmd.len) return null;

    // Find end of token.
    var end = start;
    while (end < cmd.len and cmd[end] != ' ' and cmd[end] != '\t') : (end += 1) {}

    const tok = cmd[start..end];
    if (tok.len >= buf.len) return null; // would overflow

    @memcpy(buf[0..tok.len], tok);
    return buf[0..tok.len];
}

/// Detect whether the editor command is claude-pager-open itself (avoids
/// infinite recursion).
pub fn isSelf(cmd: []const u8) bool {
    var buf: [256]u8 = undefined;
    const tok = firstToken(cmd, &buf) orelse return false;
    // Find basename of the token.
    const base = if (std.mem.lastIndexOfScalar(u8, tok, '/')) |idx|
        tok[idx + 1 ..]
    else
        tok;
    return std.mem.indexOf(u8, base, "claude-pager") != null;
}

/// Check that the editor binary exists and is executable.
/// Handles both absolute paths and bare names (searched via PATH).
pub fn editorExists(cmd: []const u8) bool {
    var buf: [256]u8 = undefined;
    const tok = firstToken(cmd, &buf) orelse return false;

    // Need a null-terminated copy for access(2).
    var nul_buf: [257]u8 = undefined;
    @memcpy(nul_buf[0..tok.len], tok);
    nul_buf[tok.len] = 0;

    // Absolute path — check directly.
    if (tok[0] == '/') {
        return std.c.access(@ptrCast(&nul_buf), X_OK) == 0;
    }

    // Bare name — search PATH entries.
    const path_env = getEnv("PATH") orelse return false;

    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        // Build dir/tok\0 into a stack buffer.
        var full: [2048]u8 = undefined;
        const needed = dir.len + 1 + tok.len + 1; // "dir/tok\0"
        if (needed > full.len) continue;
        @memcpy(full[0..dir.len], dir);
        full[dir.len] = '/';
        @memcpy(full[dir.len + 1 .. dir.len + 1 + tok.len], tok);
        full[dir.len + 1 + tok.len] = 0;
        if (std.c.access(@ptrCast(&full), X_OK) == 0) return true;
    }
    return false;
}

/// Extract the basename token of an editor command string into `buf`.
/// Returns a slice into `buf`.
pub fn basename(editor: []const u8, buf: []u8) []const u8 {
    var tok_buf: [256]u8 = undefined;
    const tok = firstToken(editor, &tok_buf) orelse return "";
    const base = if (std.mem.lastIndexOfScalar(u8, tok, '/')) |idx|
        tok[idx + 1 ..]
    else
        tok;
    if (base.len == 0 or base.len > buf.len) return "";
    @memcpy(buf[0..base.len], base);
    return buf[0..base.len];
}

/// Return true if the editor is a known GUI editor.
pub fn isKnownGuiEditor(editor: []const u8) bool {
    var buf: [256]u8 = undefined;
    const base = basename(editor, &buf);
    if (base.len == 0) return false;
    for (gui_editors) |name| {
        if (std.mem.eql(u8, base, name)) return true;
    }
    return false;
}

/// Return true if the editor is a terminal (TUI) editor.
/// Respects the CLAUDE_PAGER_EDITOR_TYPE env override ("tui" / "gui").
pub fn isTerminalEditor(editor: []const u8) bool {
    // Env override: CLAUDE_PAGER_EDITOR_TYPE=tui|gui
    if (getEnv("CLAUDE_PAGER_EDITOR_TYPE")) |override| {
        if (std.mem.eql(u8, override, "tui")) return true;
        if (std.mem.eql(u8, override, "gui")) return false;
    }

    var buf: [256]u8 = undefined;
    const base = basename(editor, &buf);
    if (base.len == 0) return false;
    for (tui_editors) |name| {
        if (std.mem.eql(u8, base, name)) return true;
    }
    return false;
}

// ── Tests ────────────────────────────────────────────────────────────────────

/// Internal name-only check (bypasses env override) for testing the lists.
fn isTerminalEditorName(base_name: []const u8) bool {
    for (tui_editors) |name| {
        if (std.mem.eql(u8, base_name, name)) return true;
    }
    return false;
}

test "terminal editor names in tui list" {
    // Test the classification lists directly, bypassing the env override.
    try std.testing.expect(isTerminalEditorName("nvim"));
    try std.testing.expect(isTerminalEditorName("vim"));
    try std.testing.expect(isTerminalEditorName("vi"));
    try std.testing.expect(isTerminalEditorName("nano"));
    try std.testing.expect(isTerminalEditorName("emacs"));
    try std.testing.expect(isTerminalEditorName("helix"));
    try std.testing.expect(isTerminalEditorName("hx"));
    try std.testing.expect(isTerminalEditorName("kak"));
    try std.testing.expect(isTerminalEditorName("micro"));
    try std.testing.expect(isTerminalEditorName("lvim"));
    try std.testing.expect(isTerminalEditorName("kakoune"));
    try std.testing.expect(isTerminalEditorName("amp"));
    try std.testing.expect(isTerminalEditorName("dte"));
    try std.testing.expect(isTerminalEditorName("mcedit"));
}

test "gui editor names not in tui list" {
    // GUI editors and emacsclient are NOT in the tui list.
    try std.testing.expect(!isTerminalEditorName("code"));
    try std.testing.expect(!isTerminalEditorName("cursor"));
    try std.testing.expect(!isTerminalEditorName("zed"));
    try std.testing.expect(!isTerminalEditorName("subl"));
    try std.testing.expect(!isTerminalEditorName("bbedit"));
    try std.testing.expect(!isTerminalEditorName("emacsclient")); // GUI client, not in tui list
    try std.testing.expect(!isTerminalEditorName("fleet"));
}

test "isTerminalEditor with env override" {
    // When CLAUDE_PAGER_EDITOR_TYPE=gui, everything returns false.
    // When CLAUDE_PAGER_EDITOR_TYPE=tui, everything returns true.
    // We test the override logic by checking what getEnv returns and ensuring
    // isTerminalEditor is consistent with it.
    const override = getEnv("CLAUDE_PAGER_EDITOR_TYPE");
    if (override) |ov| {
        if (std.mem.eql(u8, ov, "gui")) {
            try std.testing.expect(!isTerminalEditor("nvim")); // overridden to gui
            try std.testing.expect(!isTerminalEditor("code")); // overridden to gui
        } else if (std.mem.eql(u8, ov, "tui")) {
            try std.testing.expect(isTerminalEditor("code")); // overridden to tui
            try std.testing.expect(isTerminalEditor("nvim")); // overridden to tui
        }
    } else {
        // No override: test natural classification.
        try std.testing.expect(isTerminalEditor("nvim"));
        try std.testing.expect(!isTerminalEditor("code"));
        try std.testing.expect(!isTerminalEditor("emacsclient"));
    }
}

test "isKnownGuiEditor detects gui editors" {
    try std.testing.expect(isKnownGuiEditor("code"));
    try std.testing.expect(isKnownGuiEditor("cursor"));
    try std.testing.expect(isKnownGuiEditor("zed"));
    try std.testing.expect(isKnownGuiEditor("subl"));
    try std.testing.expect(isKnownGuiEditor("open"));
    try std.testing.expect(isKnownGuiEditor("fleet"));
    try std.testing.expect(isKnownGuiEditor("/usr/bin/code -w"));
    // Terminal editors are not known GUI
    try std.testing.expect(!isKnownGuiEditor("nvim"));
    try std.testing.expect(!isKnownGuiEditor("vim"));
    try std.testing.expect(!isKnownGuiEditor("emacsclient")); // not in either list
}

test "basename extracts command name" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("code", basename("/usr/bin/code -w", &buf));
    try std.testing.expectEqualStrings("nvim", basename("nvim", &buf));
    try std.testing.expectEqualStrings("vim", basename("/usr/local/bin/vim +3 file.txt", &buf));
    try std.testing.expectEqualStrings("emacsclient", basename("emacsclient -c -n", &buf));
    // Empty input
    try std.testing.expectEqualStrings("", basename("", &buf));
}

test "isSelf detects claude-pager variants" {
    try std.testing.expect(isSelf("claude-pager-open"));
    try std.testing.expect(isSelf("/usr/local/bin/claude-pager-open"));
    try std.testing.expect(isSelf("/path/to/claude-pager-open --flag"));
    try std.testing.expect(!isSelf("nvim"));
    try std.testing.expect(!isSelf("code"));
    try std.testing.expect(!isSelf(""));
}

test "editorExists finds real binaries" {
    // /bin/sh should always exist
    try std.testing.expect(editorExists("/bin/sh"));
    // A non-existent absolute path should return false
    try std.testing.expect(!editorExists("/nonexistent/bin/fakeeditor-zzz"));
    // PATH-based: "sh" should be found via PATH
    try std.testing.expect(editorExists("sh"));
    // A nonsense bare name should not be found
    try std.testing.expect(!editorExists("fakeeditor-zzz-notreal"));
}
