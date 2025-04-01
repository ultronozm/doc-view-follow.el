;;; doc-dual-view.el --- Sync two windows showing the same document  -*- lexical-binding: t; -*-

;; Copyright (C) 2024  Paul D. Nelson

;; Author: Paul D. Nelson <nelson.paul.david@gmail.com>
;; Version: 0.1
;; URL: https://github.com/ultronozm/doc-dual-view.el
;; Package-Requires: ((emacs "27.1"))
;; Keywords: convenience

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This package provides a minor mode, `doc-dual-view-mode', that
;; synchronizes page navigation between two windows displaying the
;; same document, making it so that when you navigate to a page in one
;; window, the other window will navigate to a neighboring page, so
;; that the second window is always one page ahead of the first.

;; Supports `doc-view-mode' and `pdf-view-mode'.  You can customize
;; the `doc-dual-view-modes' variable to add support for additional
;; document viewing modes or modify the behavior for existing modes.

;;; Code:

(require 'timer)

(defgroup doc-dual-view nil
  "Synchronize pages between two windows displaying the same document."
  :group 'convenience)

(defcustom doc-dual-view-modes
  '((pdf-view-mode
     (pdf-view-goto-page
      pdf-view-next-page-command
      pdf-view-previous-page-command)
     (lambda () (pdf-view-current-page))
     (lambda () (pdf-cache-number-of-pages))
     pdf-view-goto-page)
    (doc-view-mode
     (doc-view-goto-page
      doc-view-next-page
      doc-view-previous-page)
     (lambda () (doc-view-current-page))
     (lambda () (doc-view-last-page-number))
     doc-view-goto-page))
  "Alist for supported modes.
Given by (major-mode (goto-funcs) current-page-func max-page-func
redisplay-func)."
  :type '(repeat (list (symbol :tag "Major Mode")
                       (repeat :tag "Goto Page Functions" symbol)
                       (function :tag "Current Page Function")
                       (function :tag "Max Page Function")
                       (function :tag "Redisplay Function"))))

(defvar-local doc-dual-view--redisplay-timer nil
  "Timer for delayed redisplay.")

(defun doc-dual-view--order-windows (windows)
  "Order WINDOWS based on their position, leftmost (or topmost if equal) first."
  (sort windows (lambda (a b)
                  (let ((edges-a (window-edges a))
                        (edges-b (window-edges b)))
                    (or (< (car edges-a) (car edges-b))
                        (and (= (car edges-a) (car edges-b))
                             (< (cadr edges-a) (cadr edges-b))))))))

(defun doc-dual-view--sync-pages (&rest _args)
  "Sync pages between windows showing the same document."
  (let* ((mode-funcs (assoc major-mode doc-dual-view-modes))
         (goto-funcs (nth 1 mode-funcs))
         (current-page-func (nth 2 mode-funcs))
         (max-page-func (nth 3 mode-funcs))
         (redisplay-func (nth 4 mode-funcs)))
    (when mode-funcs
      (let* ((windows (doc-dual-view--order-windows
                       (get-buffer-window-list nil nil nil)))
             (current-window (selected-window))
             (window-index (cl-position current-window windows))
             (current-page (funcall current-page-func))
             (max-page (funcall max-page-func)))
        
        ;; Only proceed if we found our window in the list and have multiple windows
        (when (and window-index (> (length windows) 1))
          ;; Temporarily remove advice to prevent recursion
          (dolist (func goto-funcs)
            (advice-remove func #'doc-dual-view--sync-pages))
          
          (unwind-protect
              (progn
                ;; Create a list of target pages for all windows
                (let ((target-pages
                       (cl-loop for i from 0 below (length windows)
                                collect (cond
                                         ((< i window-index)
                                          (max 1 (- current-page (- window-index i))))
                                         ((> i window-index)
                                          (min max-page (+ current-page (- i window-index))))
                                         (t current-page)))))
                  
                  ;; Apply the target pages to each window
                  (cl-loop for win in windows
                           for target-page in target-pages
                           for i from 0
                           when (and (not (eq win current-window))
                                     (window-live-p win))
                           do (with-selected-window win
                                (let ((current (funcall current-page-func)))
                                  (when (not (= current target-page))
                                    (funcall (car goto-funcs) target-page)
                                    ;; Use a unique timer for each window
                                    (let ((timer-sym (intern (format "doc-dual-view--redisplay-timer-%d" i))))
                                      (when (and (boundp timer-sym)
                                                 (timerp (symbol-value timer-sym)))
                                        (cancel-timer (symbol-value timer-sym)))
                                      (set timer-sym
                                           (run-with-idle-timer
                                            0.001 nil
                                            (lambda (w f p)
                                              (when (window-live-p w)
                                                (with-selected-window w
                                                  (funcall f p))))
                                            win redisplay-func target-page)))))))))
            
            ;; Re-add advice after execution
            (dolist (func goto-funcs)
              (advice-add func :after #'doc-dual-view--sync-pages))))))))

(defun doc-dual-view--schedule-redisplay (window redisplay-func page)
  "Schedule a redisplay for WINDOW using REDISPLAY-FUNC to show PAGE."
  (when doc-dual-view--redisplay-timer
    (cancel-timer doc-dual-view--redisplay-timer))
  (setq doc-dual-view--redisplay-timer
        (run-with-idle-timer
         0.001 nil
         (lambda (win func pg)
           (when (window-live-p win)
             (with-selected-window win
               (funcall func pg))))
         window redisplay-func page)))


;;;###autoload
(define-minor-mode doc-dual-view-mode
  "Minor mode to sync pages between two windows showing the same document."
  :global nil
  (dolist (mode-funcs doc-dual-view-modes)
    (let ((goto-funcs (cadr mode-funcs)))
      (dolist (goto-func goto-funcs)
        (if doc-dual-view-mode
            (advice-add goto-func :after #'doc-dual-view--sync-pages)
          (advice-remove goto-func #'doc-dual-view--sync-pages)))))
  (when (not doc-dual-view-mode)
    (when doc-dual-view--redisplay-timer
      (cancel-timer doc-dual-view--redisplay-timer)
      (setq doc-dual-view--redisplay-timer nil))))

(defun doc-dual-view--maybe-enable ()
  "Enable `doc-dual-view-mode' if appropriate for this buffer."
  (when (assq major-mode doc-dual-view-modes)
    (doc-dual-view-mode 1)))

;;;###autoload
(define-globalized-minor-mode global-doc-dual-view-mode
  doc-dual-view-mode
  doc-dual-view--maybe-enable)

(provide 'doc-dual-view)
;;; doc-dual-view.el ends here
