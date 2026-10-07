// claude-pager integration for pi (https://github.com/earendil-works/pi).
//
// pi launches its external editor (Ctrl-G) with pi's own environment and no
// session information. This extension exports the current session file into
// that environment so emacs/pi-emacs-prompt can show the exact transcript.
//
// session_start fires on startup, reload, /new, /resume and /fork, so the
// variable always names the active session. Ephemeral sessions (--no-session)
// have no file; the variable is removed and the editor opens without context.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const VAR = "CLAUDE_PAGER_PI_SESSION_FILE";

export default function (pi: ExtensionAPI) {
	pi.on("session_start", (_event, ctx) => {
		const file = ctx.sessionManager.getSessionFile();
		if (file) process.env[VAR] = file;
		else delete process.env[VAR];
	});
}
