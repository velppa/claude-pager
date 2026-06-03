# Golden Plain-Render Fixtures

These are **SYNTHETIC** (hand-crafted, no private data) transcript fixtures used to gate the Zig port of `claude-pager`.

## Files

| File | Description |
|------|-------------|
| `sampleN.jsonl` | Synthetic `.jsonl` transcript input |
| `sampleN.plain.txt` | Golden plain-text output from the C build |

## Feature coverage

| Feature | sample0 | sample1 | sample2 |
|---------|---------|---------|---------|
| user + assistant plain text turns | yes | yes | yes |
| markdown `**bold**` and `` `code` `` inline | yes | | yes |
| fenced code block (│ left rail) | yes | yes | |
| markdown table (box rules) | yes | | yes |
| bare URL (OSC-8 linkified, stripped to plain) | yes | | yes |
| wide/CJK character (世界) | | yes | yes |
| long line forcing wrap at cols=110 | | | yes |
| `tool_use` block | | yes | yes |
| `tool_result` block | | yes | yes |
| `thinking` block (dropped from output) | yes | | yes |

## How goldens were generated

```bash
cd bin && make && cd ..
tests/gen_golden.sh
```

Parameters: **cols=110**, **ctx_limit=200000**.

The script compiles a tiny driver against `bin/pager.o`, calls `pager_render_plain()` for each `sampleN.jsonl`, and writes `sampleN.plain.txt`.

## Zig port contract

The Zig port must reproduce each `*.plain.txt` **byte-for-byte** from its corresponding `*.jsonl` at cols=110, ctx_limit=200000. Run `tests/gen_golden.sh` to regenerate goldens from the C build if the C renderer changes.
