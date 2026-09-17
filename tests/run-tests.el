;;; run-tests.el --- Batch test entry point -*- lexical-binding: t; -*-
(require 'package)
(setq load-prefer-newer t)
(let ((directory (getenv "EMACS_PACKAGE_DIR")))
  (when directory
    (dolist (entry (directory-files directory t "^[^.].*"))
      (when (file-directory-p entry) (add-to-list 'load-path entry)))))
(when (getenv "AGENT_SHELL_DIR")
  (add-to-list 'load-path (getenv "AGENT_SHELL_DIR")))
(add-to-list 'load-path (expand-file-name ".." (file-name-directory load-file-name)))
(load (expand-file-name "queue-tests.el" (file-name-directory load-file-name)) nil t)
(ert-run-tests-batch-and-exit)
