# CLAUDE.md — claude-pager

Fast Zig transcript pager for Claude Code, with Emacs prompt-editing integration.

## Build & test

- Build: `zig build` (default `ReleaseSmall`). Debug: `zig build -Doptimize=Debug`.
- Test: `zig build test` (tests always run with full runtime safety).
- Toolchain: Zig 0.16 (via mise). APIs assume 0.16 — note std churn (e.g. no
  `std.process.Child.run`, no `std.Thread.sleep`, `getenv` scans `std.c.environ`).
- Binaries land in `zig-out/bin/`; `bin/`, `zig-out/`, `.zig-cache/` are gitignored.

## Layout

- `src/main_open.zig` — entrypoint for `claude-pager-open` (the `$EDITOR` shim).
- `src/` — Zig sources: `render*.zig`, `ansi.zig` (theme-agnostic 16-color
  palette), `transcript.zig`, `settings.zig`, `editor.zig`, `open.zig`.
- `tests/fixtures/` — sample transcripts + plain-text goldens, wired in via
  `addAnonymousImport` in `build.zig`.
- `emacs/`, `shim/` — Emacs integration + session-transcript hooks.

## Versioning

This project uses **v0.N.9OCTAL** versioning:

- `N` = total commit count on `HEAD` (`git rev-list --count HEAD`).
- `9OCTAL` = the full commit SHA re-encoded hex→octal, prefixed with `9`. The
  `9` is self-identifying (octal digits are only 0-7) and the value decodes
  back to the SHA: `echo "obase=16; ibase=8; <octal>" | bc`.

Computed at build time in `build.zig` (`computeVersion`) and exposed as the
`build_options.version` constant. Print it with `claude-pager --version`.
Outside a git checkout it falls back to `v0.0.9dev`.

## Workflow for this project

Unlike the user's other repos: **DO commit, and DO build a new version.**

- After a change: run `zig build` + `zig build test`, then commit.
- Because the version is derived from git state, committing and rebuilding
  automatically bumps the version (new `N`, new SHA → new octal). "Build a new
  version" = commit, then `zig build`.
