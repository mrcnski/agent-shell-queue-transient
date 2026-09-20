;;; agent-shell-queue-transient.el --- Manage pending agent prompts -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.76.1") (transient "0.8"))
;; Keywords: tools, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Enable `agent-shell-queue-transient-mode', then invoke
;; `agent-shell-queue-transient'.  Queue controls use agent-shell internals.

;;; Code:

(require 'agent-shell)
(require 'agent-shell-prompt-queue)
(require 'transient)
(require 'seq)
(require 'map)

(defvar-local agent-shell-queue-transient--paused nil
  "Non-nil when this shell's queue is explicitly paused.")
(defvar-local agent-shell-queue-transient--holds 0
  "Number of active queue editing operations in this shell.")
(defvar-local agent-shell-queue-transient--deferred nil
  "Non-nil when an attempt to advance this queue was deferred.")
(defvar agent-shell-queue-transient-mode)

(defun agent-shell-queue-transient--buffer ()
  "Return the shell captured by the current menu, or resolve a shell.
The menu's scope is honoured while it is being set up, redisplayed, or
running one of its commands; otherwise resolve from the current buffer."
  (let ((buffer (or (transient-scope 'agent-shell-queue-transient)
                    (agent-shell--shell-buffer :no-create t))))
    (unless (buffer-live-p buffer)
      (user-error "The queue's shell is no longer live"))
    buffer))

(defun agent-shell-queue-transient--pending ()
  "Return the current shell's pending queue."
  ;; Upstream plans to drop the migration shim; keep working once it does.
  (when (fboundp 'agent-shell--prompt-queue-migrate)
    (agent-shell--prompt-queue-migrate))
  (map-elt agent-shell--state :pending-prompts))

(defun agent-shell-queue-transient--blocked-p ()
  "Return non-nil when the current shell's queue must not advance."
  (or agent-shell-queue-transient--paused
      (> agent-shell-queue-transient--holds 0)))

(defun agent-shell-queue-transient--process (original &rest args)
  "Call ORIGINAL with ARGS unless queue processing is held or paused."
  (if (agent-shell-queue-transient--blocked-p)
      (setq agent-shell-queue-transient--deferred t)
    (apply original args)))

(defun agent-shell-queue-transient--submit (original prompt)
  "Call ORIGINAL with PROMPT, respecting a paused or held shell queue."
  (with-current-buffer (agent-shell--shell-buffer :no-create t)
    (if (agent-shell-queue-transient--blocked-p)
        (progn
          (unless (shell-maker-busy)
            (setq agent-shell-queue-transient--deferred t))
          (agent-shell--prompt-queue-enqueue :prompt prompt))
      (funcall original prompt))))

(defun agent-shell-queue-transient--resume (original &rest args)
  "Unpause the shell and call ORIGINAL with ARGS."
  (with-current-buffer (agent-shell--shell-buffer :no-create t)
    (setq agent-shell-queue-transient--paused nil
          agent-shell-queue-transient--deferred nil)
    (apply original args)))

(defun agent-shell-queue-transient--held (function)
  "Run FUNCTION in the target shell with automatic advancement held.
Only a deferred advancement is retried when the hold ends.  A queue
stopped by an error remains stopped.  Cancellation also releases the hold."
  (let ((buffer (agent-shell-queue-transient--buffer)))
    (with-current-buffer buffer
      (setq agent-shell-queue-transient--holds
            (1+ agent-shell-queue-transient--holds))
      (unwind-protect
          (funcall function)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (setq agent-shell-queue-transient--holds
                  (1- agent-shell-queue-transient--holds))
            (when (and (zerop agent-shell-queue-transient--holds)
                       agent-shell-queue-transient--deferred
                       (not agent-shell-queue-transient--paused)
                       (not (shell-maker-busy)))
              (setq agent-shell-queue-transient--deferred nil)
              (agent-shell--prompt-queue-process-next))))))))

(defun agent-shell-queue-transient--label (prompt index width)
  "Return PROMPT as a numbered single line no wider than WIDTH.
INDEX is the prompt's zero-based position in the queue."
  (format "%d: %s" (1+ index)
          (truncate-string-to-width
           (replace-regexp-in-string "[\n\r]+" " " prompt)
           width nil nil "…")))

(defun agent-shell-queue-transient--select ()
  "Read the index of a pending prompt in the current shell."
  (let ((choices (seq-map-indexed
                  (lambda (prompt index)
                    (cons (agent-shell-queue-transient--label prompt index 90)
                          index))
                  (agent-shell-queue-transient--pending))))
    (unless choices (user-error "No pending prompts"))
    (or (alist-get (completing-read "Prompt: " choices nil t)
                   choices nil nil #'equal)
        (user-error "No prompt selected"))))

(defun agent-shell-queue-transient-add ()
  "Read a prompt and enqueue it, or send immediately when idle."
  (interactive)
  (with-current-buffer (agent-shell-queue-transient--buffer)
    (call-interactively #'agent-shell-prompt-queue)))

(defun agent-shell-queue-transient--enqueue (front)
  "Read a prompt and enqueue it at the back, or at the front if FRONT.
Do not start an idle queue.  An already running queue continues normally."
  (agent-shell-queue-transient--held
   (lambda ()
     (let ((prompt (agent-shell--prompt-queue-read)))
       (unless (string-blank-p prompt)
         (if front
             (map-put! agent-shell--state :pending-prompts
                       (cons prompt (agent-shell-queue-transient--pending)))
           (agent-shell--prompt-queue-enqueue :prompt prompt)))))))

(defun agent-shell-queue-transient-add-front ()
  "Read a prompt to enqueue before all waiting entries."
  (interactive)
  (agent-shell-queue-transient--enqueue t))

(defun agent-shell-queue-transient-add-back ()
  "Read a prompt to enqueue after all waiting entries."
  (interactive)
  (agent-shell-queue-transient--enqueue nil))

(defun agent-shell-queue-transient-edit ()
  "Edit a pending prompt, preserving its position."
  (interactive)
  (agent-shell-queue-transient--held
   (lambda ()
     (let* ((index (agent-shell-queue-transient--select))
            (old (nth index (agent-shell-queue-transient--pending)))
            (prompt (agent-shell--prompt-queue-read :initial old))
            ;; Re-read: the queue may have been replaced while reading.
            (current (agent-shell-queue-transient--pending)))
       (when (string-blank-p prompt) (user-error "Prompt cannot be empty"))
       (unless (eq old (nth index current))
         (user-error "Queue changed; select the prompt again"))
       (setcar (nthcdr index current) prompt)))))

(defun agent-shell-queue-transient-view ()
  "Display the full text of a pending prompt."
  (interactive)
  (agent-shell-queue-transient--held
   (lambda ()
     (let ((prompt (nth (agent-shell-queue-transient--select)
                        (agent-shell-queue-transient--pending))))
       (with-help-window "*Agent queue prompt*"
         (princ prompt))))))

(defun agent-shell-queue-transient-move-first ()
  "Move a selected pending prompt to the front of the queue."
  (interactive)
  (agent-shell-queue-transient--held
   (lambda ()
     (let* ((index (agent-shell-queue-transient--select))
            (pending (agent-shell-queue-transient--pending)))
       (map-put! agent-shell--state :pending-prompts
                 (cons (nth index pending)
                       (append (seq-take pending index)
                               (seq-drop pending (1+ index)))))))))

(defun agent-shell-queue-transient-remove ()
  "Select and remove one pending prompt."
  (interactive)
  (agent-shell-queue-transient--held
   (lambda ()
     (agent-shell-prompt-queue-remove (agent-shell-queue-transient--select)))))

(defun agent-shell-queue-transient-clear ()
  "Clear the pending queue after confirmation."
  (interactive)
  (agent-shell-queue-transient--held
   (lambda () (agent-shell-prompt-queue-remove))))

(defun agent-shell-queue-transient-pause ()
  "Pause queue processing without interrupting the active turn."
  (interactive)
  (with-current-buffer (agent-shell-queue-transient--buffer)
    (setq agent-shell-queue-transient--paused t)
    (force-mode-line-update t)))

(defun agent-shell-queue-transient-resume ()
  "Resume automatic processing, starting the next prompt when idle."
  (interactive)
  (with-current-buffer (agent-shell-queue-transient--buffer)
    (agent-shell-prompt-queue-resume)
    (force-mode-line-update t)))

(defun agent-shell-queue-transient--description ()
  "Return the target shell's buffer name for the heading."
  (buffer-name (agent-shell-queue-transient--buffer)))

(defun agent-shell-queue-transient--status ()
  "Return the queue state with subdued styling."
  (with-current-buffer (agent-shell-queue-transient--buffer)
    (propertize
     (format "%s · %s · %d waiting"
             (if (shell-maker-busy) "working" "idle")
             (if agent-shell-queue-transient--paused "paused" "automatic")
             (length (agent-shell-queue-transient--pending)))
     'face 'shadow)))

(defun agent-shell-queue-transient--preview ()
  "Return a preview of the first three queued entries."
  (with-current-buffer (agent-shell-queue-transient--buffer)
    (mapconcat (lambda (entry)
                 (concat "  " (agent-shell-queue-transient--label
                               (car entry) (cdr entry) 70)))
               (seq-map-indexed #'cons
                                (seq-take (agent-shell-queue-transient--pending) 3))
               "\n")))

;;;###autoload
(transient-define-prefix agent-shell-queue-transient ()
  "Manage prompts for the current shell or viewport.
With an empty, unpaused queue, read a new prompt directly when busy.
When idle, move to the end of the shell input in its existing window,
leave an open viewport composer and its cursor unchanged, or switch a
response viewport to editing mode.  Preserve drafts and submit nothing.
Otherwise show the queue menu."
  [:description agent-shell-queue-transient--description
   (:info #'agent-shell-queue-transient--status)
   (:info #'agent-shell-queue-transient--preview)]
  [["Add"
    ("f" "Add to front…" agent-shell-queue-transient-add-front :transient t)
    ("b" "Add to back…" agent-shell-queue-transient-add-back :transient t)]
   ["Queued prompts"
    ("v" "View full prompt…" agent-shell-queue-transient-view)
    ("e" "Edit…" agent-shell-queue-transient-edit :transient t)
    ("m" "Move to front…" agent-shell-queue-transient-move-first :transient t)
    ("d" "Remove…" agent-shell-queue-transient-remove :transient t)
    ("D" "Clear queue…" agent-shell-queue-transient-clear :transient t)]
   ["Processing"
    ("p" "Pause after current" agent-shell-queue-transient-pause :transient t)
    ("r" "Resume queue" agent-shell-queue-transient-resume :transient t)]]
  (interactive)
  (unless agent-shell-queue-transient-mode
    (user-error "Enable agent-shell-queue-transient-mode first"))
  (let ((shell (agent-shell--shell-buffer :no-create t)))
    (cond
     ((with-current-buffer shell
        (or agent-shell-queue-transient--paused
            (agent-shell-queue-transient--pending)))
      (transient-setup 'agent-shell-queue-transient nil nil :scope shell))
     ((with-current-buffer shell (shell-maker-busy))
      (agent-shell-queue-transient-add))
     ((derived-mode-p 'agent-shell-viewport-edit-mode)
      nil)
     ((derived-mode-p 'agent-shell-viewport-view-mode)
      (agent-shell-viewport--show-buffer :shell-buffer shell :edit t))
     (t
      (if-let* ((window (get-buffer-window shell)))
          (select-window window)
        (switch-to-buffer shell))
      (goto-char (point-max))))))

(defun agent-shell-queue-transient--mode-line ()
  "Return a pause indicator for a shell or its viewport."
  (when (derived-mode-p 'agent-shell-mode 'agent-shell-viewport-view-mode
                       'agent-shell-viewport-edit-mode)
    (when-let* ((buffer (agent-shell--shell-buffer :no-create t :no-error t)))
      (when (buffer-local-value 'agent-shell-queue-transient--paused buffer)
        " Queue paused"))))

;;;###autoload
(define-minor-mode agent-shell-queue-transient-mode
  "Enable per-shell queue pause and safe queue editing globally.
Disabling clears pause state without submitting any pending prompts."
  :global t
  :group 'agent-shell
  (dolist (entry '((agent-shell--prompt-queue-process-next . agent-shell-queue-transient--process)
                   (agent-shell-prompt-queue . agent-shell-queue-transient--submit)
                   (agent-shell-prompt-queue-resume . agent-shell-queue-transient--resume)))
    (if agent-shell-queue-transient-mode
        (advice-add (car entry) :around (cdr entry))
      (advice-remove (car entry) (cdr entry))))
  (if agent-shell-queue-transient-mode
      (add-to-list 'global-mode-string
                   '(:eval (agent-shell-queue-transient--mode-line)) t)
    (setq global-mode-string
          (delete '(:eval (agent-shell-queue-transient--mode-line)) global-mode-string))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (setq agent-shell-queue-transient--paused nil
              agent-shell-queue-transient--deferred nil))))
  (force-mode-line-update t))

(provide 'agent-shell-queue-transient)
;;; agent-shell-queue-transient.el ends here
