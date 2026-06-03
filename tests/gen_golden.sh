#!/usr/bin/env bash
# Regenerate golden plain-render fixtures from the C build.
# Usage: tests/gen_golden.sh   (run from repo root, after `cd bin && make`)
set -euo pipefail
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
[[ -f bin/pager.o ]] || { echo "run 'cd bin && make' first (need bin/pager.o)" >&2; exit 1; }
cat > "$tmp/cpg_golden.c" <<'EOF'
#include "pager.h"
int main(int c, char **v){ return pager_render_plain(v[1], v[2], 110, 200000); }
EOF
"${CC:-clang}" -O2 -Ibin -o "$tmp/cpg_golden" "$tmp/cpg_golden.c" bin/pager.o
for jf in tests/fixtures/sample*.jsonl; do
  "$tmp/cpg_golden" "$jf" "${jf%.jsonl}.plain.txt"
done
echo "golden fixtures regenerated at cols=110 ctx=200000"
