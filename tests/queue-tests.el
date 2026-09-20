;;; queue-tests.el --- Queue behavior tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'agent-shell-queue-transient)

(defmacro asqt-test-shell (&rest body)
  "Run BODY with an isolated shell and real queue functions.
BODY sees SHELL (the shell buffer), BUSY (settable busy state) and
SENT (prompts submitted so far, newest first)."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (setq major-mode 'agent-shell-mode)
     (setq-local agent-shell--state (list (cons :pending-prompts nil)))
     (let ((shell (current-buffer))
           (busy nil) sent)
       (cl-letf (((symbol-function 'agent-shell--shell-buffer)
                  (lambda (&rest _) shell))
                 ((symbol-function 'shell-maker-busy) (lambda (&rest _) busy))
                 ((symbol-function 'agent-shell--prompt-queue-echo) #'ignore)
                 ((symbol-function 'agent-shell--insert-to-shell-buffer)
                  (lambda (&rest args)
                    (push (plist-get args :text) sent)
                    (setq busy t))))
         (unwind-protect
             (progn (agent-shell-queue-transient-mode 1) ,@body)
           (agent-shell-queue-transient-mode -1))))))

(ert-deftest asqt-add-busy-and-idle ()
  (asqt-test-shell
    (agent-shell-prompt-queue "first")
    (should (equal sent '("first")))
    (agent-shell-prompt-queue "second")
    (should (equal (agent-shell-queue-transient--pending) '("second")))))

(ert-deftest asqt-pause-and-resume ()
  (asqt-test-shell
    (agent-shell-queue-transient-pause)
    (agent-shell-prompt-queue "first")
    (agent-shell-prompt-queue "second")
    (agent-shell--prompt-queue-process-next)
    (should-not sent)
    (should (equal (agent-shell-queue-transient--pending) '("first" "second")))
    (agent-shell-queue-transient-resume)
    (should-not agent-shell-queue-transient--paused)
    (should (equal sent '("first")))
    (should (equal (agent-shell-queue-transient--pending) '("second")))))

(ert-deftest asqt-resume-while-busy-does-not-send ()
  (asqt-test-shell
    (setq busy t)
    (agent-shell-queue-transient-pause)
    (agent-shell-prompt-queue "later")
    (agent-shell-queue-transient-resume)
    (should-not sent)
    (should-not agent-shell-queue-transient--paused)))

(ert-deftest asqt-edit-defers-completion-and-preserves-order ()
  (asqt-test-shell
    (setq busy t)
    (agent-shell-prompt-queue "first")
    (agent-shell-prompt-queue "second")
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "2: second"))
              ((symbol-function 'agent-shell--prompt-queue-read)
               (lambda (&rest args)
                 (should (equal (plist-get args :initial) "second"))
                 (setq busy nil)
                 (agent-shell--prompt-queue-process-next)
                 (should-not sent)
                 "edited")))
      (agent-shell-queue-transient-edit))
    (should (equal sent '("first")))
    (should (equal (agent-shell-queue-transient--pending) '("edited")))
    (should (zerop agent-shell-queue-transient--holds))))

(ert-deftest asqt-cancel-releases-hold ()
  (asqt-test-shell
    (setq busy t)
    (agent-shell-prompt-queue "first")
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "1: first"))
              ((symbol-function 'agent-shell--prompt-queue-read)
               (lambda (&rest _)
                 (setq busy nil)
                 (agent-shell--prompt-queue-process-next)
                 (signal 'quit nil))))
      (condition-case nil (agent-shell-queue-transient-edit) (quit nil)))
    (should (equal sent '("first")))
    (should (zerop agent-shell-queue-transient--holds))))

(ert-deftest asqt-edit-stopped-queue-does-not-start-it ()
  (asqt-test-shell
    (map-put! agent-shell--state :pending-prompts (list "first"))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "1: first"))
              ((symbol-function 'agent-shell--prompt-queue-read) (lambda (&rest _) "edited")))
      (agent-shell-queue-transient-edit))
    (should-not sent)
    (should (equal (agent-shell-queue-transient--pending) '("edited")))))

(ert-deftest asqt-empty-edit-preserves-prompt ()
  (asqt-test-shell
    (map-put! agent-shell--state :pending-prompts (list "first"))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "1: first"))
              ((symbol-function 'agent-shell--prompt-queue-read) (lambda (&rest _) "  ")))
      (should-error (agent-shell-queue-transient-edit) :type 'user-error))
    (should (equal (agent-shell-queue-transient--pending) '("first")))
    (should (zerop agent-shell-queue-transient--holds))))

(ert-deftest asqt-reorder-and-add-front ()
  (asqt-test-shell
    (setq busy t)
    (agent-shell-prompt-queue "first")
    (agent-shell-prompt-queue "second")
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "2: second"))
              ((symbol-function 'agent-shell--prompt-queue-read) (lambda (&rest _) "urgent")))
      (agent-shell-queue-transient-move-first)
      (should (equal (agent-shell-queue-transient--pending) '("second" "first")))
      (agent-shell-queue-transient-add-front))
    (should (equal (agent-shell-queue-transient--pending) '("urgent" "second" "first")))
    (should-not sent)))

(ert-deftest asqt-remove-duplicate-by-position-and-clear ()
  (asqt-test-shell
    (setq busy t)
    (dolist (prompt '("same" "middle" "same")) (agent-shell-prompt-queue prompt))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "3: same"))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (agent-shell-queue-transient-remove)
      (should (equal (agent-shell-queue-transient--pending) '("same" "middle")))
      (agent-shell-queue-transient-clear)
      (should-not (agent-shell-queue-transient--pending)))))

(ert-deftest asqt-pause-is-per-shell-and-disable-cleans-up ()
  (asqt-test-shell
    (agent-shell-queue-transient-pause)
    (with-temp-buffer (should-not agent-shell-queue-transient--paused))
    (agent-shell-prompt-queue "later")
    (agent-shell-queue-transient-mode -1)
    (should-not agent-shell-queue-transient--paused)
    (should-not sent)
    (should-not (advice-member-p #'agent-shell-queue-transient--process
                                 'agent-shell--prompt-queue-process-next))))

(ert-deftest asqt-opening-menu-only-inspects ()
  (asqt-test-shell
    (map-put! agent-shell--state :pending-prompts (list "later"))
    (cl-letf (((symbol-function 'transient-setup)
               (lambda (name _layout _edit &rest args)
                 (should (eq name 'agent-shell-queue-transient))
                 (should (eq (plist-get args :scope) (current-buffer)))
                 (should (equal (buffer-name) (agent-shell-queue-transient--description))))))
      (agent-shell-queue-transient))
    (should-not sent)
    (should-not agent-shell-queue-transient--paused)))

(ert-deftest asqt-menu-scope-wins-over-current-buffer ()
  (asqt-test-shell
    (let ((prefix (transient-prefix :command 'agent-shell-queue-transient :scope shell))
          (other (transient-prefix :command 'ignore :scope shell)))
      (with-temp-buffer
        (cl-letf (((symbol-function 'agent-shell--shell-buffer)
                   (lambda (&rest _) (current-buffer))))
          ;; Suffix commands see `transient-current-prefix'.
          (let ((transient-current-prefix prefix))
            (should (eq (agent-shell-queue-transient--buffer) shell)))
          ;; Setup and redisplay see `transient--prefix'.
          (let ((transient--prefix prefix))
            (should (eq (agent-shell-queue-transient--buffer) shell)))
          ;; Another menu's scope is ignored.
          (let ((transient-current-prefix other))
            (should (eq (agent-shell-queue-transient--buffer) (current-buffer)))))))))

(ert-deftest asqt-real-transient-layout ()
  (asqt-test-shell
    (map-put! agent-shell--state :pending-prompts (list "later"))
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (unwind-protect
          (progn
            (agent-shell-queue-transient)
            (should (eq (oref transient--prefix scope) (current-buffer)))
            (with-current-buffer (get-buffer transient--buffer-name)
              (goto-char (point-min))
              (search-forward "idle · automatic · 1 waiting")
              (should (eq (get-text-property (1- (point)) 'face) 'shadow))
              (should (string-match-p "f Add to front" (buffer-string)))
              (should (string-match-p "b Add to back" (buffer-string)))
              (should-not (string-match-p "Send prompt" (buffer-string)))))
        (transient--emergency-exit)))))

(ert-deftest asqt-add-front-idle-and-paused ()
  (asqt-test-shell
    (cl-letf (((symbol-function 'agent-shell--prompt-queue-read) (lambda (&rest _) "urgent")))
      (agent-shell-queue-transient-pause)
      (agent-shell-queue-transient-add-front)
      (should-not sent)
      (should (equal (agent-shell-queue-transient--pending) '("urgent")))
      (agent-shell-queue-transient-resume)
      (should (equal sent '("urgent")))
      (setq busy nil)
      (agent-shell-queue-transient-add-front)
      (should (equal sent '("urgent")))
      (should (equal (agent-shell-queue-transient--pending) '("urgent"))))))

(ert-deftest asqt-pause-indicator-in-viewport ()
  (asqt-test-shell
    (agent-shell-queue-transient-pause)
    (should (equal (agent-shell-queue-transient--mode-line) " Queue paused"))
    (with-temp-buffer
      (setq major-mode 'agent-shell-viewport-view-mode)
      (should (equal (agent-shell-queue-transient--mode-line) " Queue paused")))))

(ert-deftest asqt-dead-target-errors ()
  (let ((dead (generate-new-buffer " *dead queue*")))
    (kill-buffer dead)
    (cl-letf (((symbol-function 'agent-shell--shell-buffer) (lambda (&rest _) dead)))
      (should-error (agent-shell-queue-transient--buffer) :type 'user-error))))

(ert-deftest asqt-empty-selection-errors ()
  (asqt-test-shell
    (map-put! agent-shell--state :pending-prompts (list "first"))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "")))
      (should-error (agent-shell-queue-transient-edit) :type 'user-error))
    (should (equal (agent-shell-queue-transient--pending) '("first")))
    (should (zerop agent-shell-queue-transient--holds))))

(ert-deftest asqt-clearing-deferred-queue-does-not-send ()
  (asqt-test-shell
    (setq busy t)
    (agent-shell-prompt-queue "later")
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (&rest _)
                 (setq busy nil)
                 (agent-shell--prompt-queue-process-next)
                 t)))
      (agent-shell-queue-transient-clear))
    (should-not sent)
    (should-not (agent-shell-queue-transient--pending))))

(ert-deftest asqt-empty-busy-reads-without-menu ()
  (asqt-test-shell
    (setq busy t)
    (insert "existing draft")
    (cl-letf (((symbol-function 'agent-shell--prompt-queue-read)
               (lambda (&rest _) "follow-up"))
              ((symbol-function 'transient-setup)
               (lambda (&rest _) (ert-fail "Unexpected menu"))))
      (agent-shell-queue-transient))
    (should (equal (agent-shell-queue-transient--pending) '("follow-up")))
    (should (equal (buffer-string) "existing draft"))
    (should-not sent)))

(ert-deftest asqt-empty-busy-cancel-preserves-draft ()
  (asqt-test-shell
    (setq busy t)
    (insert "existing draft")
    (cl-letf (((symbol-function 'agent-shell--prompt-queue-read)
               (lambda (&rest _) (signal 'quit nil))))
      (condition-case nil (agent-shell-queue-transient) (quit nil)))
    (should (equal (buffer-string) "existing draft"))
    (should-not (agent-shell-queue-transient--pending))
    (should-not sent)))

(ert-deftest asqt-empty-idle-focuses-shell-input ()
  (asqt-test-shell
    (insert "existing draft")
    (goto-char (point-min))
    (save-window-excursion
      (cl-letf (((symbol-function 'transient-setup)
                 (lambda (&rest _) (ert-fail "Unexpected menu"))))
        (agent-shell-queue-transient))
      (should (eq (window-buffer) shell))
      (should (= (point) (point-max)))
      (should (equal (buffer-string) "existing draft")))
    (should-not sent)))

(ert-deftest asqt-empty-idle-focuses-viewport-composer ()
  (asqt-test-shell
    (let ((shell (current-buffer)) opened)
      (with-temp-buffer
        (setq major-mode 'agent-shell-viewport-view-mode)
        (cl-letf (((symbol-function 'agent-shell-viewport--show-buffer)
                   (lambda (&rest args) (setq opened args))))
          (agent-shell-queue-transient)))
      (should (eq (plist-get opened :shell-buffer) shell))
      (should (plist-get opened :edit)))
    (should-not sent)))

(ert-deftest asqt-empty-paused-opens-menu ()
  (asqt-test-shell
    (agent-shell-queue-transient-pause)
    (let (opened)
      (cl-letf (((symbol-function 'transient-setup)
                 (lambda (&rest _) (setq opened t))))
        (agent-shell-queue-transient))
      (should opened))
    (should agent-shell-queue-transient--paused)
    (should-not sent)))

(ert-deftest asqt-agent-finishes-during-direct-entry ()
  (asqt-test-shell
    (setq busy t)
    (cl-letf (((symbol-function 'agent-shell--prompt-queue-read)
               (lambda (&rest _) (setq busy nil) "follow-up")))
      (agent-shell-queue-transient))
    (should (equal sent '("follow-up")))
    (should-not (agent-shell-queue-transient--pending))))

(ert-deftest asqt-add-positions-preserve-stopped-queue ()
  (asqt-test-shell
    (map-put! agent-shell--state :pending-prompts (list "existing"))
    (let ((inputs '("last" "first")))
      (cl-letf (((symbol-function 'agent-shell--prompt-queue-read)
                 (lambda (&rest _) (pop inputs))))
        (agent-shell-queue-transient-add-back)
        (agent-shell-queue-transient-add-front)))
    (should (equal (agent-shell-queue-transient--pending) '("first" "existing" "last")))
    (should-not sent)
    (agent-shell-queue-transient-resume)
    (should (equal sent '("first")))))

(ert-deftest asqt-add-back-keeps-paused-queue-paused ()
  (asqt-test-shell
    (agent-shell-queue-transient-pause)
    (cl-letf (((symbol-function 'agent-shell--prompt-queue-read)
               (lambda (&rest _) "later")))
      (agent-shell-queue-transient-add-back))
    (should agent-shell-queue-transient--paused)
    (should-not sent)
    (should (equal (agent-shell-queue-transient--pending) '("later")))))

(ert-deftest asqt-add-front-allows-running-queue-to-continue ()
  (asqt-test-shell
    (setq busy t)
    (agent-shell-prompt-queue "existing")
    (cl-letf (((symbol-function 'agent-shell--prompt-queue-read)
               (lambda (&rest _)
                 (setq busy nil)
                 (agent-shell--prompt-queue-process-next)
                 "first")))
      (agent-shell-queue-transient-add-front))
    (should (equal sent '("first")))
    (should (equal (agent-shell-queue-transient--pending) '("existing")))))

(ert-deftest asqt-idle-shell-reuses-window-despite-popup-rules ()
  (asqt-test-shell
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (insert "draft")
      (goto-char (point-min))
      (let ((window (selected-window))
            (windows (window-list))
            (display-buffer-alist
             '((".*" (display-buffer-pop-up-window) (inhibit-same-window . t)))))
        (agent-shell-queue-transient)
        (should (eq (selected-window) window))
        (should (equal (window-list) windows))
        (should (= (point) (point-max)))
        (should (equal (buffer-string) "draft"))))))

(ert-deftest asqt-idle-edit-keeps-composer-and-point ()
  (asqt-test-shell
    (with-temp-buffer
      (setq major-mode 'agent-shell-viewport-edit-mode)
      (insert "draft")
      (goto-char 3)
      (cl-letf (((symbol-function 'agent-shell-viewport--show-buffer)
                 (lambda (&rest _) (ert-fail "Redisplayed existing composer"))))
        (agent-shell-queue-transient))
      (should (= (point) 3))
      (should (equal (buffer-string) "draft")))))

(ert-deftest asqt-view-shows-full-prompt ()
  (asqt-test-shell
    (map-put! agent-shell--state :pending-prompts (list "first line\nsecond line"))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "1: first line second line")))
      (save-window-excursion
        (agent-shell-queue-transient-view)
        (should (string-match-p "\\`first line\nsecond line\n?\\'"
                                (with-current-buffer "*Agent queue prompt*"
                                  (buffer-string))))))
    (should (equal (agent-shell-queue-transient--pending) '("first line\nsecond line")))
    (should (zerop agent-shell-queue-transient--holds))))

(ert-deftest asqt-hold-release-keeps-paused-queue-paused ()
  (asqt-test-shell
    (agent-shell-queue-transient-pause)
    ;; Idle and paused: the submission is queued and its advance deferred.
    (agent-shell-prompt-queue "later")
    (should agent-shell-queue-transient--deferred)
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "1: later"))
              ((symbol-function 'agent-shell--prompt-queue-read) (lambda (&rest _) "edited")))
      (agent-shell-queue-transient-edit))
    (should-not sent)
    (should agent-shell-queue-transient--paused)
    (should (equal (agent-shell-queue-transient--pending) '("edited")))
    (agent-shell-queue-transient-resume)
    (should (equal sent '("edited")))))

(ert-deftest asqt-hold-release-waits-for-idle ()
  (asqt-test-shell
    (setq busy t)
    (agent-shell-prompt-queue "later")
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "1: later"))
              ((symbol-function 'agent-shell--prompt-queue-read)
               (lambda (&rest _)
                 ;; Deferred by the hold while the shell is still busy.
                 (agent-shell--prompt-queue-process-next)
                 "edited")))
      (agent-shell-queue-transient-edit))
    (should-not sent)
    (setq busy nil)
    (agent-shell--prompt-queue-process-next)
    (should (equal sent '("edited")))))

(ert-deftest asqt-nested-holds-release-once ()
  (asqt-test-shell
    (setq busy t)
    (agent-shell-prompt-queue "later")
    (agent-shell-queue-transient--held
     (lambda ()
       (agent-shell-queue-transient--held
        (lambda ()
          (should (= agent-shell-queue-transient--holds 2))
          (setq busy nil)
          (agent-shell--prompt-queue-process-next)))
       ;; The inner release must not advance while the outer hold is open.
       (should (= agent-shell-queue-transient--holds 1))
       (should-not sent)))
    (should (zerop agent-shell-queue-transient--holds))
    (should (equal sent '("later")))))

(ert-deftest asqt-killing-shell-during-hold-is-safe ()
  (asqt-test-shell
    (agent-shell-queue-transient--held (lambda () (kill-buffer shell)))
    (should-not (buffer-live-p shell))))

(ert-deftest asqt-blank-add-is-ignored ()
  (asqt-test-shell
    (map-put! agent-shell--state :pending-prompts (list "existing"))
    (cl-letf (((symbol-function 'agent-shell--prompt-queue-read) (lambda (&rest _) " \n ")))
      (agent-shell-queue-transient-add-front)
      (agent-shell-queue-transient-add-back))
    (should (equal (agent-shell-queue-transient--pending) '("existing")))
    (should-not sent)
    (should (zerop agent-shell-queue-transient--holds))))

(ert-deftest asqt-edit-refuses-replaced-queue ()
  (asqt-test-shell
    (map-put! agent-shell--state :pending-prompts (list "first" "second"))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "2: second"))
              ((symbol-function 'agent-shell--prompt-queue-read)
               (lambda (&rest _)
                 ;; Something else rewrote the queue while the user was typing.
                 (map-put! agent-shell--state :pending-prompts (list "first" "other"))
                 "edited")))
      (should-error (agent-shell-queue-transient-edit) :type 'user-error))
    (should (equal (agent-shell-queue-transient--pending) '("first" "other")))
    (should (zerop agent-shell-queue-transient--holds))))

(ert-deftest asqt-select-on-empty-queue-errors ()
  (asqt-test-shell
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) (ert-fail "Unexpected prompt"))))
      (dolist (command '(agent-shell-queue-transient-edit
                         agent-shell-queue-transient-view
                         agent-shell-queue-transient-move-first
                         agent-shell-queue-transient-remove))
        (should-error (funcall command) :type 'user-error)))
    (should (zerop agent-shell-queue-transient--holds))))

(ert-deftest asqt-entry-requires-mode ()
  (asqt-test-shell
    (agent-shell-queue-transient-mode -1)
    (cl-letf (((symbol-function 'transient-setup)
               (lambda (&rest _) (ert-fail "Unexpected menu"))))
      (should-error (agent-shell-queue-transient) :type 'user-error))))

(ert-deftest asqt-status-reflects-busy-and-paused ()
  (asqt-test-shell
    (should (equal (substring-no-properties (agent-shell-queue-transient--status))
                   "idle · automatic · 0 waiting"))
    (setq busy t)
    (agent-shell-queue-transient-pause)
    (map-put! agent-shell--state :pending-prompts (list "a" "b"))
    (let ((status (agent-shell-queue-transient--status)))
      (should (equal (substring-no-properties status) "working · paused · 2 waiting"))
      (should (eq (get-text-property 0 'face status) 'shadow)))))

(ert-deftest asqt-label-folds-newlines-and-truncates ()
  (should (equal (agent-shell-queue-transient--label "one\r\ntwo\nthree" 0 90)
                 "1: one two three"))
  (let ((label (agent-shell-queue-transient--label (make-string 100 ?x) 2 20)))
    (should (string-prefix-p "3: xxx" label))
    (should (string-suffix-p "…" label))
    (should (= (string-width label) (+ (length "3: ") 20)))))

(ert-deftest asqt-preview-shows-first-three-entries ()
  (asqt-test-shell
    (map-put! agent-shell--state :pending-prompts
              (list "one\ntwo" (make-string 100 ?x) "three" "four"))
    (let ((lines (agent-shell-queue-transient--preview)))
      (should (equal (length lines) 3))
      (should (equal (nth 0 lines) "  1: one two"))
      (should (string-prefix-p "  2: xxx" (nth 1 lines)))
      (should (string-suffix-p "…" (nth 1 lines)))
      (should (equal (nth 2 lines) "  3: three")))))

(ert-deftest asqt-mode-line-is-silent-unless-paused-in-a-shell ()
  (asqt-test-shell
    (should-not (agent-shell-queue-transient--mode-line))
    (agent-shell-queue-transient-pause)
    (with-temp-buffer
      (should-not (agent-shell-queue-transient--mode-line)))
    (cl-letf (((symbol-function 'agent-shell--shell-buffer) (lambda (&rest _) nil)))
      (should-not (agent-shell-queue-transient--mode-line)))))

(ert-deftest asqt-mode-toggles-global-mode-string ()
  (asqt-test-shell
    (should (member agent-shell-queue-transient--mode-line-construct global-mode-string))
    (agent-shell-queue-transient-mode -1)
    (should-not (member agent-shell-queue-transient--mode-line-construct global-mode-string))))

(ert-deftest asqt-heading-children-append-one-info-per-entry ()
  (asqt-test-shell
    (map-put! agent-shell--state :pending-prompts (list "alpha" "beta"))
    (let ((children (agent-shell-queue-transient--heading-children '(status))))
      (should (eq (car children) 'status))
      (should (= (length children) 3)))
    (map-put! agent-shell--state :pending-prompts nil)
    (should (equal (agent-shell-queue-transient--heading-children '(status))
                   '(status)))))

(ert-deftest asqt-real-transient-aligns-queue-entries ()
  (asqt-test-shell
    (map-put! agent-shell--state :pending-prompts (list "alpha" "beta"))
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (unwind-protect
          (progn
            (agent-shell-queue-transient)
            (should (oref transient--prefix refresh-suffixes))
            (let* ((lines (with-current-buffer (get-buffer transient--buffer-name)
                            (split-string (buffer-string) "\n")))
                   (find (lambda (text)
                           (let ((line (seq-find (lambda (l) (string-search text l)) lines)))
                             (should line)
                             (string-search text line))))
                   (status (funcall find "idle · automatic · 2 waiting"))
                   (first (funcall find "1: alpha"))
                   (second (funcall find "2: beta")))
              ;; Entries line up with each other, indented under the status.
              (should (= first second))
              (should (> first status))))
        (transient--emergency-exit)))))
