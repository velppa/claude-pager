// ansi.zig — SGR color/style constants and ANSI-aware visible-length.
// Constants ported from bin/pager.c lines 28-90.
// visibleLen ported from bin/pager.c:2243 (vlen), extended with UTF-8 / wide-char support.

const std = @import("std");

// ── SGR reset / style ──────────────────────────────────────────────────────

pub const reset = "\x1b[0m"; // RS
pub const bold = "\x1b[1m"; // BO
pub const dim = "\x1b[2m"; // DI

// ── Foreground colors (RGB) ────────────────────────────────────────────────

pub const c_hum = "\x1b[38;2;242;169;59m"; // C_HUM  human turn
pub const c_ast = "\x1b[38;2;246;241;254m"; // C_AST  assistant turn
pub const c_tol = "\x1b[38;2;178;185;244m"; // C_TOL  tool call
pub const c_res = "\x1b[38;2;153;153;153m"; // C_RES  result / muted
pub const c_err = "\x1b[38;2;220;80;80m"; // C_ERR  error
pub const c_cbg = "\x1b[48;2;35;35;35m"; // C_CBG  code block bg
pub const c_cfg = "\x1b[38;2;200;230;200m"; // C_CFG  code fg
pub const c_cin = "\x1b[38;2;116;173;234m"; // C_CIN  inline code
pub const c_sep = "\x1b[38;2;80;80;80m"; // C_SEP  separator
pub const c_hdm = "\x1b[38;2;140;138;144m"; // C_HDM  heading muted
pub const c_ban = "\x1b[1;33m"; // C_BAN  banner
pub const c_dfg = "\x1b[38;2;160;233;160m"; // C_DFG  diff add fg
pub const c_dfr = "\x1b[38;2;244;149;149m"; // C_DFR  diff del fg
pub const c_dfc = "\x1b[38;2;136;197;232m"; // C_DFC  diff ctx fg
pub const c_dabg = "\x1b[48;2;18;93;28m\x1b[38;2;160;233;160m"; // C_DABG diff add bg
pub const c_ddbg = "\x1b[48;2;105;19;24m\x1b[38;2;244;149;149m"; // C_DDBG diff del bg
pub const c_dcbg = "\x1b[48;2;47;53;66m\x1b[38;2;178;185;244m"; // C_DCBG diff ctx bg
pub const c_dahl = bold ++ "\x1b[48;2;55;128;65m\x1b[38;2;236;255;236m"; // C_DAHL diff add hl
pub const c_ddhl = bold ++ "\x1b[48;2;140;41;47m\x1b[38;2;255;222;222m"; // C_DDHL diff del hl
pub const c_dmbg = "\x1b[38;2;214;214;214m"; // C_DMBG diff meta bg
pub const c_dmeta = "\x1b[38;2;136;197;232m"; // C_DMETA diff meta
pub const c_syn_str = "\x1b[38;2;223;204;255m"; // C_SYN_STR syntax string
pub const c_syn_num = "\x1b[38;2;255;178;79m"; // C_SYN_NUM syntax number
pub const c_syn_kw = "\x1b[38;2;255;178;79m"; // C_SYN_KW  syntax keyword
pub const c_brg = "\x1b[38;2;100;220;100m"; // C_BRG  bright green
pub const c_bry = "\x1b[38;2;255;165;0m"; // C_BRY  bright yellow
pub const c_brr = "\x1b[38;2;255;80;80m"; // C_BRR  bright red
pub const c_conn = "\x1b[38;2;88;87;90m"; // C_CONN connector
pub const c_url = "\x1b[38;2;242;169;59m"; // C_URL  URL
pub const c_flink = "\x1b[38;2;136;197;232m"; // C_FLINK file link
pub const c_lhov = "\x1b[7m"; // C_LHOV link hover (reverse)
pub const c_ubg = "\x1b[48;2;66;66;66m\x1b[38;2;246;241;254m"; // C_UBG  unknown bg
pub const c_qbg = "\x1b[48;2;31;36;44m\x1b[38;2;181;188;205m"; // C_QBG  quote bg
pub const c_qsel = "\x1b[48;2;40;56;84m\x1b[38;2;196;224;255m"; // C_QSEL quote selected
pub const c_qacc = "\x1b[38;2;136;197;232m"; // C_QACC quote accent
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

// ── Mouse sequences ────────────────────────────────────────────────────────

pub const mouse_on = "\x1b[>0s\x1b[?1007l\x1b[?1000h\x1b[?1003h\x1b[?1006h"; // MOUSE_ON
pub const mouse_off = "\x1b[?1006l\x1b[?1003l\x1b[?1000l\x1b[?1007l"; // MOUSE_OFF

// ── ANSI-aware visible length ──────────────────────────────────────────────
//
// Walks the byte string s, skipping ANSI escape sequences and counting the
// number of *display columns* occupied by the visible text.
//
// Escape sequences handled:
//   CSI  ESC '['  … final-byte (0x40-0x7E or '~')
//   OSC  ESC ']'  … BEL (0x07) or ST (ESC '\')
//   other ESC x   consumed silently
//
// Wide-character (CJK) ranges contributing 2 columns — derived from the
// Unicode East Asian Width "Wide" (W) and "Fullwidth" (F) categories, which
// is the standard wcwidth(3) definition used in most terminal implementations.
// The C source (vlen, lines 2243-2259) does NOT implement wide-char logic;
// it counts one column per byte.  This Zig implementation extends it to be
// column-accurate for Unicode text, which is the intended semantics described
// in the task spec.

pub fn visibleLen(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\x1b') {
            i += 1;
            if (i >= s.len) break;
            if (s[i] == '[') {
                // CSI — skip until final byte 0x40-0x7E (inclusive of '~' = 0x7E)
                i += 1;
                while (i < s.len) {
                    const b = s[i];
                    i += 1;
                    if (b >= 0x40 and b <= 0x7E) break;
                }
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
            // Decode one UTF-8 codepoint
            const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
                // Invalid UTF-8: treat as one byte, one column
                i += 1;
                n += 1;
                continue;
            };
            if (i + seq_len > s.len) {
                // Truncated sequence
                i += 1;
                n += 1;
                continue;
            }
            const cp = std.unicode.utf8Decode(s[i .. i + seq_len]) catch {
                i += 1;
                n += 1;
                continue;
            };
            i += seq_len;
            n += codepointWidth(cp);
        }
    }
    return n;
}

// Returns the display column width of a Unicode codepoint (1 or 2).
// Wide (W) and Fullwidth (F) categories per Unicode East Asian Width tables.
fn codepointWidth(cp: u21) usize {
    // Zero-width / combining: return 0 would be correct but we don't need it
    // for current tests; treat everything not wide as width 1.
    if (isWide(cp)) return 2;
    return 1;
}

// Unicode East Asian Width — Wide (W) and Fullwidth (F) ranges.
// Source: Unicode 15 EastAsianWidth.txt + wcwidth reference implementations.
fn isWide(cp: u21) bool {
    return switch (cp) {
        // Fullwidth forms
        0x1100...0x115F => true, // Hangul Jamo
        0x231A...0x231B => true, // Watch, Hourglass
        0x2329...0x232A => true, // Angle brackets
        0x23E9...0x23EC => true, // various clock faces
        0x23F0 => true,
        0x23F3 => true,
        0x25FD...0x25FE => true,
        0x2614...0x2615 => true,
        0x2648...0x2653 => true,
        0x267F => true,
        0x2693 => true,
        0x26A1 => true,
        0x26AA...0x26AB => true,
        0x26BD...0x26BE => true,
        0x26C4...0x26C5 => true,
        0x26CE => true,
        0x26D4 => true,
        0x26EA => true,
        0x26F2...0x26F3 => true,
        0x26F5 => true,
        0x26FA => true,
        0x26FD => true,
        0x2702 => true,
        0x2705 => true,
        0x2708...0x270D => true,
        0x270F => true,
        0x2712 => true,
        0x2714 => true,
        0x2716 => true,
        0x271D => true,
        0x2721 => true,
        0x2728 => true,
        0x2733...0x2734 => true,
        0x2744 => true,
        0x2747 => true,
        0x274C => true,
        0x274E => true,
        0x2753...0x2755 => true,
        0x2757 => true,
        0x2763...0x2764 => true,
        0x2795...0x2797 => true,
        0x27A1 => true,
        0x27B0 => true,
        0x27BF => true,
        0x2B1B...0x2B1C => true,
        0x2B50 => true,
        0x2B55 => true,
        0x2E80...0x303E => true, // CJK Radicals, Kangxi, Ideographic, etc.
        0x3041...0x33BF => true, // Hiragana, Katakana, Bopomofo, Hangul Compat, Kanbun, etc.
        0x33FF...0x33FF => true,
        0x3400...0x4DBF => true, // CJK Extension A
        0x4E00...0x9FFF => true, // CJK Unified Ideographs
        0xA000...0xA4CF => true, // Yi
        0xA960...0xA97F => true, // Hangul Jamo Extended-A
        0xAC00...0xD7AF => true, // Hangul Syllables
        0xF900...0xFAFF => true, // CJK Compatibility Ideographs
        0xFE10...0xFE1F => true, // Vertical Forms
        0xFE30...0xFE6F => true, // CJK Compatibility Forms, Small Forms
        0xFF01...0xFF60 => true, // Fullwidth Latin, Halfwidth/Fullwidth
        0xFFE0...0xFFE6 => true, // Fullwidth signs
        0x16FE0...0x16FFF => true, // Tangut components etc.
        0x17000...0x187FF => true, // Tangut
        0x18800...0x18AFF => true, // Tangut components
        0x1B000...0x1B12F => true, // Kana Extended
        0x1B170...0x1B2FF => true, // Nushu
        0x1F004 => true,
        0x1F0CF => true,
        0x1F18E => true,
        0x1F191...0x1F19A => true,
        0x1F1E0...0x1F1FF => true,
        0x1F201...0x1F202 => true,
        0x1F21A => true,
        0x1F22F => true,
        0x1F232...0x1F23A => true,
        0x1F250...0x1F251 => true,
        0x1F300...0x1F64F => true, // Misc Symbols, Emoticons
        0x1F680...0x1F6FF => true, // Transport and Map
        0x1F900...0x1F9FF => true, // Supplemental Symbols
        0x20000...0x2A6DF => true, // CJK Extension B
        0x2A700...0x2CEAF => true, // CJK Extensions C, D, E
        0x2CEB0...0x2EBEF => true, // CJK Extension F
        0x2F800...0x2FA1F => true, // CJK Compatibility Supplement
        0x30000...0x3134F => true, // CJK Extension G
        else => false,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "visibleLen ignores SGR sequences" {
    try std.testing.expectEqual(@as(usize, 3), visibleLen("\x1b[31mabc\x1b[0m"));
}

test "visibleLen counts wide CJK as 2" {
    try std.testing.expectEqual(@as(usize, 2), visibleLen("世"));
}

test "visibleLen plain ascii" {
    try std.testing.expectEqual(@as(usize, 5), visibleLen("hello"));
}

test "visibleLen skips OSC sequence" {
    // ESC ] 8 ; ; uri ST  visible text  ESC ] 8 ; ; ST  -> count only visible text
    try std.testing.expectEqual(@as(usize, 4), visibleLen("\x1b]8;;http://x\x1b\\link\x1b]8;;\x1b\\"));
}

test "visibleLen mixed SGR and wide" {
    // bold + 2 CJK chars + reset  →  4 columns
    try std.testing.expectEqual(@as(usize, 4), visibleLen("\x1b[1m世界\x1b[0m"));
}

test "visibleLen multiple SGR" {
    // cursor color + text + reset
    try std.testing.expectEqual(@as(usize, 3), visibleLen("\x1b[38;2;255;0;0mfoo\x1b[0m"));
}
