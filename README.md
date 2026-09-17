# agent-shell-queue-transient

A Transient menu for the prompt queue in agent-shell.

Features:

- Add to the front or the back of the queue.
- Edit prompts in the queue.
- Delete prompts, or clear the queue.
- ... more?

## Usage

Invoke `agent-shell-queue-transient` in an agent-shell buffer.

The entry command adapts to the queue:

- Busy with an empty queue: read a new prompt directly.
- Idle with an empty queue: move to the end of the shell input.
- Pending prompts or an explicitly paused queue: show the menu.

## Installation

Not on MELPA, but you can do:

```elisp
(add-to-list 'load-path "~/.emacs.d/packages/agent-shell-queue-transient")
(require 'agent-shell-queue-transient)
(agent-shell-queue-transient-mode 1)
(keymap-set agent-shell-mode-map "C-<return>" #'agent-shell-queue-transient)
(with-eval-after-load 'agent-shell-viewport
  (keymap-set agent-shell-viewport-view-mode-map "C-<return>" #'agent-shell-queue-transient)
  (keymap-set agent-shell-viewport-edit-mode-map "C-<return>" #'agent-shell-queue-transient))
```

## Compatibility

Uses private agent-shell functions and its `:pending-prompts` state.  Upstream
changes may require updates here.

## Testing

With agent-shell and its dependencies installed:

```sh
EMACS_PACKAGE_DIR="$HOME/.local/emacs/elpa" \
AGENT_SHELL_DIR=/path/to/agent-shell \
emacs --batch -Q -l tests/run-tests.el
```

## License

GPL-3.0-or-later.
