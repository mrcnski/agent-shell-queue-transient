# agent-shell-queue-transient

A Transient menu for the prompt queue in agent-shell. Works from shell and
viewport buffers, and captures the target session when the menu opens.

```elisp
(add-to-list 'load-path "~/.emacs.d/packages/agent-shell-queue-transient")
(require 'agent-shell-queue-transient)
(agent-shell-queue-transient-mode 1)
(keymap-set agent-shell-mode-map "C-c q" #'agent-shell-queue-transient)
(with-eval-after-load 'agent-shell-viewport
  (keymap-set agent-shell-viewport-view-mode-map "C-c q" #'agent-shell-queue-transient)
  (keymap-set agent-shell-viewport-edit-mode-map "C-c q" #'agent-shell-queue-transient))
```

| Key | Action |
| --- | --- |
| `a` | Add a prompt; send immediately when idle unless paused |
| `n` | Add a prompt ahead of the waiting queue |
| `v` | View the complete text of a queued prompt |
| `e` | Edit a prompt in place |
| `m` | Move a prompt to the front |
| `d` | Remove a selected prompt, with confirmation |
| `D` | Clear the waiting queue, with confirmation |
| `p` | Pause after the active turn |
| `r` | Resume automatic processing |
| `C-g` | Dismiss the menu |

The menu previews the first three pending prompts. Selection uses completion,
with numbered entries so duplicate text is distinguishable. Viewing opens a
help buffer; other actions keep the menu open and refresh it. Existing compose
buffers are left intact; adding and editing use agent-shell's prompt reader,
including its completion hooks.

Pause belongs to the shell, is shown in the shell and viewport mode line, and
lasts until explicitly resumed. It does not interrupt an active turn. Calls to
`agent-shell-prompt-queue` also honor pause. Direct prompt submission outside
that API remains available. Pause state is not persisted across Emacs restarts.

While selecting, editing, reordering, or confirming removal, queue advancement
is temporarily held. If a successful turn completes during that operation,
advancement is retried afterward, including after cancellation. A queue stopped
by failure is not started merely by viewing or editing it. Opening the menu
itself does not pause or advance the queue.

## Compatibility

Uses private agent-shell functions and its `:pending-prompts` state. Tested
against the local agent-shell checkout (0.76.1). Upstream changes may require
updates here. Disabling `agent-shell-queue-transient-mode` removes advice and
clears pause state without submitting anything. Use the normal queue resume
command to continue a waiting queue afterward.

## Tests

With agent-shell and its dependencies installed:

```sh
EMACS_PACKAGE_DIR="$HOME/.local/emacs/elpa" \
AGENT_SHELL_DIR=/path/to/agent-shell \
emacs --batch -Q -l tests/run-tests.el
```

`AGENT_SHELL_DIR` is optional; it selects a checkout ahead of installed packages.
The tests exercise the real upstream queue operations, mocking agent submission
and user input. They do not contact an agent or run a full Emacs configuration.

License: GPL-3.0-or-later.
