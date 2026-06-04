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

These golden `*.plain.txt` files are **FROZEN** reference output. They were
originally generated from the now-removed C build (recoverable from git history)
at **cols=110**, **ctx_limit=200000**.

The generator script that originally produced these files has been deleted along
with the C sources, so the goldens are no longer regenerated — they are checked
in as fixed reference output.

## Zig port contract

The Zig renderer's tests assert **byte-identical** output against each
`*.plain.txt`, rendering from its corresponding `*.jsonl` at cols=110,
ctx_limit=200000. If the Zig renderer's output diverges from these frozen
goldens, the tests fail.
