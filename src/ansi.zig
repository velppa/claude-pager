// ansi.zig — SGR color/style constants and ANSI-aware visible-length.
// visibleLen uses byte-count semantics (no Unicode/wide-char width): every
// non-escape byte counts as one column.

const std = @import("std");

// ── SGR reset / style ──────────────────────────────────────────────────────

pub const reset = "\x1b[0m"; // RS
pub const bold = "\x1b[1m"; // BO
pub const dim = "\x1b[2m"; // DI

// ── Theme-agnostic palette ─────────────────────────────────────────────────
// Colors use the terminal's 16-color ANSI palette (3/4-bit) and the default
// fg/bg (39/49) instead of hardcoded 24-bit RGB. This lets the user's terminal
// theme map each role, so the output reads correctly on BOTH light and dark
// backgrounds. The old palette baked in near-white foregrounds and dark
// background fills, which were invisible / jarring on a light terminal.
//   30-37 fg · 90-97 bright fg · 39 default fg · 49 default bg · 7 reverse

pub const c_hum = "\x1b[33m"; // C_HUM  human turn        — yellow
pub const c_ast = "\x1b[39m"; // C_AST  assistant turn    — default fg
pub const c_tol = "\x1b[34m"; // C_TOL  tool call         — blue
pub const c_res = "\x1b[90m"; // C_RES  result / muted    — bright black (gray)
pub const c_err = "\x1b[31m"; // C_ERR  error             — red
pub const c_cbg = "\x1b[49m"; // C_CBG  code block bg      — default bg (no fill)
pub const c_cfg = "\x1b[39m"; // C_CFG  code fg           — default fg
pub const c_cin = "\x1b[36m"; // C_CIN  inline code       — cyan
pub const c_sep = "\x1b[90m"; // C_SEP  separator         — gray
pub const c_hdm = "\x1b[90m"; // C_HDM  heading muted     — gray
pub const c_ban = "\x1b[1;33m"; // C_BAN  banner          — bold yellow
pub const c_dfg = "\x1b[32m"; // C_DFG  diff add fg       — green
pub const c_dfr = "\x1b[31m"; // C_DFR  diff del fg       — red
pub const c_dfc = "\x1b[34m"; // C_DFC  diff ctx fg       — blue
pub const c_dabg = "\x1b[49m\x1b[32m"; // C_DABG diff add  — green on default bg
pub const c_ddbg = "\x1b[49m\x1b[31m"; // C_DDBG diff del  — red on default bg
pub const c_dcbg = "\x1b[49m\x1b[34m"; // C_DCBG diff ctx  — blue on default bg
pub const c_dahl = bold ++ "\x1b[49m\x1b[32m"; // C_DAHL diff add hl — bold green
pub const c_ddhl = bold ++ "\x1b[49m\x1b[31m"; // C_DDHL diff del hl — bold red
pub const c_dmbg = "\x1b[90m"; // C_DMBG diff meta bg      — gray
pub const c_dmeta = "\x1b[34m"; // C_DMETA diff meta       — blue
pub const c_syn_str = "\x1b[35m"; // C_SYN_STR syntax string  — magenta
pub const c_syn_num = "\x1b[33m"; // C_SYN_NUM syntax number  — yellow
pub const c_syn_kw = "\x1b[33m"; // C_SYN_KW  syntax keyword  — yellow
pub const c_brg = "\x1b[32m"; // C_BRG  bright green      — green
pub const c_bry = "\x1b[33m"; // C_BRY  bright yellow     — yellow
pub const c_brr = "\x1b[31m"; // C_BRR  bright red        — red
pub const c_conn = "\x1b[90m"; // C_CONN connector        — gray
pub const c_url = "\x1b[33m"; // C_URL  URL               — yellow
pub const c_flink = "\x1b[36m"; // C_FLINK file link       — cyan
pub const c_lhov = "\x1b[7m"; // C_LHOV link hover        — reverse
pub const c_ubg = "\x1b[49m\x1b[39m"; // C_UBG  unknown    — default fg/bg
pub const c_qbg = "\x1b[49m\x1b[39m"; // C_QBG  quote      — default fg/bg
pub const c_qsel = "\x1b[7m"; // C_QSEL quote selected     — reverse
pub const c_qacc = "\x1b[36m"; // C_QACC quote accent      — cyan
pub const ul_on = "\x1b[4m"; // UL_ON  underline on
pub const ul_off = "\x1b[24m"; // UL_OFF underline off

// ── Box-drawing / misc UTF-8 literals ─────────────────────────────────────

pub const hl = "\xe2\x94\x80"; // ─  horizontal line
pub const vl = "\xe2\x94\x82"; // │  vertical line
pub const bul = "\xe2\x80\xa2"; // •  bullet
pub const chv = "\xe2\x80\xba"; // ›  chevron
pub const rec = "\xe2\x8f\xba"; // ⏺  record
pub const ell = "\xe2\x80\xa6"; // …  ellipsis
pub const emd = "\xe2\x80\x94"; // —  em dash
pub const uar = "\xe2\x86\x91"; // ↑  up arrow
pub const fblk = "\xe2\x96\x88"; // █  full block
pub const eblk = "\xe2\x96\x91"; // ░  empty block
pub const dot = "\xc2\xb7"; // ·  middle dot
pub const wrap_placeholder = "\x1f"; // unit separator (wrap marker)
pub const tl = "\xe2\x94\x8c"; // ┌  top-left corner
pub const tr = "\xe2\x94\x90"; // ┐  top-right corner
pub const bl = "\xe2\x94\x94"; // └  bottom-left corner
pub const br = "\xe2\x94\x98"; // ┘  bottom-right corner

// Mouse tracking sequences were removed with the interactive pager — nothing
// enables mouse reporting now, so terminal scroll/selection behave natively.

// ── ANSI-aware visible length ──────────────────────────────────────────────
//
// Walks the byte string s, skipping ANSI escape sequences and counting every
// remaining byte as one column. There is no Unicode/wide-char width handling.
//
// Escape sequences skipped (not counted):
//   CSI  ESC '['  … up to and including a final byte (letter or '~')
//   OSC  ESC ']'  … up to BEL (0x07) or ST (ESC '\')
//   other ESC x   consumes the single byte after ESC

pub fn visibleLen(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\x1b') {
            i += 1;
            if (i >= s.len) break;
            if (s[i] == '[') {
                // CSI — skip until a final byte (letter or '~'), then consume it.
                i += 1;
                while (i < s.len and !isCsiFinal(s[i])) i += 1;
                if (i < s.len) i += 1;
            } else if (s[i] == ']') {
                // OSC — skip until BEL or ST (ESC \)
                i += 1;
                while (i < s.len) {
                    if (s[i] == '\x07') {
                        i += 1;
                        break;
                    }
                    if (s[i] == '\x1b' and i + 1 < s.len and s[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
            } else {
                // Any other ESC x — consume the one byte after ESC
                i += 1;
            }
        } else {
            // Byte-count (no Unicode width).
            n += 1;
            i += 1;
        }
    }
    return n;
}

fn isCsiFinal(b: u8) bool {
    return (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or b == '~';
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "visibleLen ignores SGR sequences" {
    try std.testing.expectEqual(@as(usize, 3), visibleLen("\x1b[31mabc\x1b[0m"));
}

test "visibleLen counts CJK by UTF-8 bytes" {
    // visibleLen counts bytes, not display columns. "世" is 3 UTF-8 bytes → 3.
    try std.testing.expectEqual(@as(usize, 3), visibleLen("世"));
}

test "visibleLen plain ascii" {
    try std.testing.expectEqual(@as(usize, 5), visibleLen("hello"));
}

test "visibleLen skips OSC sequence" {
    // ESC ] 8 ; ; uri ST  visible text  ESC ] 8 ; ; ST  -> count only visible text
    try std.testing.expectEqual(@as(usize, 4), visibleLen("\x1b]8;;http://x\x1b\\link\x1b]8;;\x1b\\"));
}

test "visibleLen mixed SGR and CJK counts bytes" {
    // bold + 世界 (6 UTF-8 bytes) + reset → 6 (byte-count)
    try std.testing.expectEqual(@as(usize, 6), visibleLen("\x1b[1m世界\x1b[0m"));
}

test "visibleLen multiple SGR" {
    // cursor color + text + reset
    try std.testing.expectEqual(@as(usize, 3), visibleLen("\x1b[38;2;255;0;0mfoo\x1b[0m"));
}
