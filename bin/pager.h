#ifndef PAGER_H
#define PAGER_H

#include <stddef.h>

#define PAGER_QUEUE_FORMAT_VERSION 1

void run_pager(int tty_fd, const char *transcript, int editor_pid, int ctx_limit, int control_fd);
int pager_queue_attachment_for_transcript(
    const char *transcript,
    char *queue_path,
    size_t queue_path_len,
    char *queue_key,
    size_t queue_key_len
);

/* Render TRANSCRIPT to OUT_PATH as plain text (ANSI/OSC-8 escapes stripped),
 * wrapping decisions made for COLS columns. Returns 0 on success. Used by the
 * TUI editor path so a terminal editor can show the same rendered context the
 * pager would. */
int pager_render_plain(const char *transcript, const char *out_path,
                       int cols, int ctx_limit);

#endif
