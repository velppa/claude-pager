;;; claude-prompt.el --- Inline transcript when editing a Claude Code prompt -*- lexical-binding: t; -*-

;; When Claude Code's Ctrl-G opens the prompt temp file via
;; emacsclient, this shows the session transcript (read-only) above a
;; separator and lets you type your next prompt below it.  On save
;; ({C-c C-c} or {C-x #}), only the text below the separator is
;; written to the file, so Claude receives only what you typed.

;;; Code:

(require 'json)
(require 'subr-x)

(defvar claude-prompt--pending nil
  "Non-nil when the next server-opened buffer is a Claude prompt file.
Set by the editor wrapper; armed even when no transcript exists yet
(fresh session), so the keymap, header line, and separator still install.")

(defvar claude-prompt--pending-transcript nil
  "Path to transcript .jsonl set by the editor wrapper just before opening.")

(defvar claude-prompt--pending-render nil
  "Path to a plain-text transcript pre-rendered by claude-pager.
When set, its contents are used as the read-only context verbatim instead
of rendering the .jsonl ourselves, keeping a single source of truth with the
pager.")

(defvar-local claude-prompt--render-file nil
  "Buffer-local copy of the claude-pager render file for this prompt buffer.
Deleted on buffer kill (C-c C-c, C-c C-k, or manual kill); the pager names
it /tmp/claude-pager-render-<pid>.txt and never cleans it up itself.")

(defconst claude-prompt-separator
  "----->8=----- TYPE PROMPT BELOW – text above is read-only context -----"
  "Marker line; everything below it is sent as the prompt.")

(defconst claude-prompt--end-marker
  (propertize "\n" 'read-only t 'rear-nonsticky nil)
  "Unused; kept for clarity.")

(defun claude-prompt--text-from-content (content)
  "Render CONTENT (string or vector of blocks) to a readable string."
  (cond
   ((stringp content) content)
   ((vectorp content)
    (string-join
     (delq nil
           (mapcar
            (lambda (block)
              (let ((type (alist-get 'type block)))
                (cond
                 ((equal type "text") (alist-get 'text block))
                 ((equal type "tool_use")
                  (format "⚙ tool_use: %s" (alist-get 'name block)))
                 ((equal type "tool_result")
                  (let* ((c (alist-get 'content block))
                         (s (claude-prompt--text-from-content c)))
                    (format "↳ tool_result: %s"
                            (truncate-string-to-width
                             (replace-regexp-in-string "\n" " " (or s "")) 200 nil nil "…"))))
                 ((equal type "thinking") nil)
                 (t nil))))
            content))
     "\n"))
   (t "")))

(defun claude-prompt--render-transcript (jsonl-path)
  "Return readable transcript string for JSONL-PATH, or nil."
  (when (and jsonl-path (file-readable-p jsonl-path))
    (with-temp-buffer
      ;; Force utf-8: a single stray byte must not flip detection to latin-1
      ;; and mojibake every • / — in the file.
      (let ((coding-system-for-read 'utf-8))
        (insert-file-contents jsonl-path))
      (let ((out '()))
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (unless (string-empty-p line)
              (ignore-errors
                (let* ((obj (json-parse-string line :object-type 'alist
                                               :array-type 'array
                                               :null-object nil))
                       (type (alist-get 'type obj))
                       (msg (alist-get 'message obj)))
                  (when (and msg (member type '("user" "assistant")))
                    (let* ((role (alist-get 'role msg))
                           (txt (string-trim
                                 (claude-prompt--text-from-content
                                  (alist-get 'content msg)))))
                      (unless (string-empty-p txt)
                        (push (format "%s %s\n%s"
                                      (if (equal role "user") "▶" "◀")
                                      (upcase (or role "?"))
                                      txt)
                              out))))))))
          (forward-line 1))
        (when out
          (string-join (nreverse out) "\n\n"))))))

(defun claude-prompt--read-render (render-path)
  "Return contents of RENDER-PATH (pre-rendered by claude-pager), or nil."
  (when (and render-path (file-readable-p render-path))
    (with-temp-buffer
      ;; Force utf-8 (see claude-prompt--render-transcript).
      (let ((coding-system-for-read 'utf-8))
        (insert-file-contents render-path))
      (let ((s (string-trim (buffer-string))))
        (unless (string-empty-p s) s)))))

(defun claude-prompt--install (buffer transcript-path &optional render-path)
  "Insert read-only context above existing text in BUFFER.
If RENDER-PATH points to a plain-text render from claude-pager, use it
verbatim; otherwise render TRANSCRIPT-PATH (.jsonl) ourselves."
  (with-current-buffer buffer
    ;; Plain text, no markdown fontification — Claude's prompt file extension
    ;; can trigger markdown-mode otherwise. Switch first; it kills local vars,
    ;; so all setq-local/hooks below must follow it.
    (fundamental-mode)
    ;; Remember the render file so we can unlink it when the buffer dies; the
    ;; pager exec's away and cannot clean up after itself.
    (when (and render-path (file-exists-p render-path))
      (setq-local claude-prompt--render-file render-path)
      (add-hook 'kill-buffer-hook #'claude-prompt--cleanup-render nil t))
    (let* ((draft (buffer-string))
           (rendered (or (claude-prompt--read-render render-path)
                         (claude-prompt--render-transcript transcript-path)))
           (header (concat
                    (if rendered
                        (concat "=== TRANSCRIPT (read-only) ===\n\n" rendered "\n\n")
                      "=== no transcript found ===\n\n")
                    claude-prompt-separator "\n")))
      (erase-buffer)
      ;; header context — fully editable; just dimmed. Anything above the
      ;; separator is dropped on save, edited or not.
      (let ((start (point)))
        (insert header)
        (add-text-properties start (point)
                             '(font-lock-face font-lock-comment-face
                               rear-nonsticky t)))
      ;; record where the user region begins
      (setq-local claude-prompt--body-start (copy-marker (point) nil))
      ;; restore any draft below the separator
      (insert draft)
      (set-buffer-modified-p nil)
      (add-hook 'write-contents-functions #'claude-prompt--write-body nil t)
      (local-set-key (kbd "C-c C-c") #'claude-prompt-finish)
      (local-set-key (kbd "C-c C-k") #'claude-prompt-cancel)
      (setq-local header-line-format
                  "Claude prompt — type below separator, send with C-c C-c, cancel with C-c C-k")
      (claude-prompt--goto-body)
      ;; server may reposition point to top after this hook; re-assert.
      (run-at-time 0 nil
                   (lambda (buf)
                     (when (buffer-live-p buf)
                       (with-current-buffer buf (claude-prompt--goto-body))))
                   buffer))))

(defun claude-prompt--goto-body ()
  "Put point at the start of the editable body in this buffer + its window."
  (when (bound-and-true-p claude-prompt--body-start)
    (let ((pos (marker-position claude-prompt--body-start)))
      (goto-char pos)
      (dolist (win (get-buffer-window-list (current-buffer) nil t))
        (set-window-point win pos))
      (recenter-top-bottom 10))))

(defun claude-prompt--body-pos ()
  "Position where the prompt body starts: just after the last separator line.
Falls back to the recorded marker, then point-min."
  (save-excursion
    (goto-char (point-max))
    (if (search-backward claude-prompt-separator nil t)
        (progn (goto-char (match-end 0))
               (when (eolp) (forward-char 1))
               (point))
      (or (and (bound-and-true-p claude-prompt--body-start)
               (marker-position claude-prompt--body-start))
          (point-min)))))

(defun claude-prompt--write-body ()
  "Write only the text below the separator to the visited file."
  (when (bound-and-true-p claude-prompt--body-start)
    (let ((body (string-trim
                 (buffer-substring-no-properties (claude-prompt--body-pos) (point-max)))))
      (write-region body nil buffer-file-name nil 'quiet)
      (set-buffer-modified-p nil)
      t)))

(defun claude-prompt--cleanup-render ()
  "Delete this buffer's claude-pager render file if it still exists."
  (when (and claude-prompt--render-file
             (file-exists-p claude-prompt--render-file))
    (ignore-errors (delete-file claude-prompt--render-file)))
  (setq claude-prompt--render-file nil))

(defun claude-prompt-finish ()
  "Save the prompt body and kill the buffer, returning control to emacsclient.
Killing a server buffer marks the client done, so `emacsclient' returns."
  (interactive)
  (save-buffer)
  (set-buffer-modified-p nil)
  (kill-buffer))

(defun claude-prompt-cancel ()
  "Discard the prompt body and kill the buffer, sending nothing to Claude.
Writes an empty file so `emacsclient' returns with no prompt text."
  (interactive)
  (write-region "" nil buffer-file-name nil 'quiet)
  (set-buffer-modified-p nil)
  (kill-buffer))

(defun claude-prompt-setup ()
  "If a transcript is pending, turn the just-opened buffer into a prompt editor."
  (when (or claude-prompt--pending
            claude-prompt--pending-transcript
            claude-prompt--pending-render)
    (let ((tx claude-prompt--pending-transcript)
          (rf claude-prompt--pending-render))
      (setq claude-prompt--pending nil
            claude-prompt--pending-transcript nil
            claude-prompt--pending-render nil)
      (claude-prompt--install (current-buffer) tx rf))))

(add-hook 'server-switch-hook #'claude-prompt-setup)

(provide 'claude-prompt)
;;; claude-prompt.el ends here
