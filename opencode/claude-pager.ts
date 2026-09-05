import { unlink } from "node:fs/promises"

/** Open the active OpenCode session in claude-pager, then submit the edited prompt. */
export const tui = async (api: any) => {
  api.command?.register(() => [{
    value: "claude-pager.open",
    title: "Edit prompt with claude-pager",
    description: "Open the current session transcript in the configured editor",
    keybind: "ctrl+g",
    onSelect: async () => {
      if (api.route.current.name !== "session") {
        api.ui.toast({ variant: "warning", message: "Open a session before editing a prompt" })
        return
      }

      const sessionID = api.route.current.params.sessionID
      const editor = process.env.EDITOR
      if (!editor) {
        api.ui.toast({ variant: "error", message: "Set EDITOR to claude-pager" })
        return
      }

      const messages = await api.client.session.messages({ sessionID })
      if (!messages.data) {
        api.ui.toast({ variant: "error", message: "Could not read the current session" })
        return
      }

      const base = `${process.env.TMPDIR ?? "/tmp"}/claude-pager-opencode-${sessionID}`
      const transcript = `${base}.json`
      const prompt = `${base}.prompt`
      await Bun.write(transcript, JSON.stringify({
        info: api.state.session.get(sessionID),
        messages: messages.data,
      }))
      await Bun.write(prompt, "")

      try {
        const child = Bun.spawn({
          cmd: ["sh", "-c", 'exec "$EDITOR" "$1"', "sh", prompt],
          env: { ...process.env, CLAUDE_PAGER_TRANSCRIPT: transcript },
          stdin: "inherit",
          stdout: "inherit",
          stderr: "inherit",
        })
        if (await child.exited !== 0) return

        const text = await Bun.file(prompt).text()
        if (text.trim().length === 0) return
        await api.client.session.prompt({
          sessionID,
          parts: [{ type: "text", text }],
        })
      } finally {
        await Promise.all([unlink(transcript).catch(() => {}), unlink(prompt).catch(() => {})])
      }
    },
  }])
}
