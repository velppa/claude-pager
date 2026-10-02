# OpenCode integration

Install the TUI plugin:

```sh
mkdir -p ~/.config/opencode/plugins
ln -sf ./claude-pager.ts ~/.config/opencode/plugins/claude-pager.ts
```

Set `EDITOR` to the pager entrypoint before starting OpenCode:

```sh
EDITOR=/path/to/claude-pager/bin/claude-pager opencode
```

Remove any `editor_open` binding for `ctrl+g` from `~/.config/opencode/tui.json`.
The plugin owns `ctrl+g`: it exports the active session, opens the configured
editor, and sends the completed prompt to that same session.
