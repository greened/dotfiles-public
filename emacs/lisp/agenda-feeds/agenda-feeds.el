;;; agenda-feeds.el --- Generated org files for the agenda, one per source -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Greene

;; Author: David Greene <greened@obbligato.org>
;; Version: 0.1.0
;; Keywords: outlines, calendar, convenience
;; URL: https://github.com/greened/agenda-feeds
;; Package-Requires: ((emacs "28.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Answers "what am I working on today?" by turning each source of work into a
;; GENERATED org file that `org-agenda-files' can read.
;;
;; The shape matters more than any one feed:
;;
;;   * One file per source, each written whole on every refresh.  A source that
;;     fails leaves its last file in place, so the agenda degrades to stale data
;;     rather than losing everything.
;;   * Generated files are never hand-edited.  Each carries a GENERATED banner,
;;     and a refresh overwrites it without asking.  Put durable notes in your own
;;     org files and let these hold only what a source can regenerate.
;;   * Nothing here performs network I/O.  Feeds that need a network fetch (a
;;     calendar, an issue tracker) belong in an out-of-process fetcher that
;;     writes its file on a timer; this package only reads local state.  A
;;     blocking fetch inside a shared Emacs freezes the session, which is a
;;     mistake worth designing out rather than remembering.
;;
;; Feeds so far:
;;
;;   `agenda-feeds-work-items' -- in-flight branches from the gaffer work-item
;;   store: one TODO per change you are actually carrying, tagged with its Jira
;;   issue where the title names one.
;;
;; Usage:
;;
;;   (setq agenda-feeds-directory "~/lib/notes")
;;   (add-to-list 'org-agenda-files (agenda-feeds-file "work-items.org"))
;;   M-x agenda-feeds-refresh

;;; Code:

(require 'seq)
(require 'subr-x)

;; gaffer is an elpaca package loaded asynchronously; requiring it from here
;; would fail while this package loads mid-init.  Every call is guarded by
;; `fboundp', so a feed whose source is absent degrades to "no items" instead of
;; erroring.
(declare-function gaffer--items-read "gaffer")
(declare-function gaffer-item-kind "gaffer")
(declare-function gaffer-item-stage "gaffer")
(declare-function gaffer-item-title "gaffer")
(declare-function gaffer-item-repo "gaffer")
(declare-function gaffer-item-branch "gaffer")
(declare-function gaffer-item-pr-number "gaffer")
(declare-function gaffer-item-worktree "gaffer")
(declare-function gaffer-item-deferred "gaffer")
(defvar gaffer--items)

(defgroup agenda-feeds nil
  "Generated org files that feed the agenda."
  :group 'org
  :prefix "agenda-feeds-")

(defcustom agenda-feeds-directory nil
  "Directory the generated feed files are written to.
Nil means the feeds refuse to write, since guessing a location risks
overwriting a real org file.  Set it to a directory you keep for generated
content."
  :type '(choice (const :tag "Unset (feeds disabled)" nil) directory)
  :group 'agenda-feeds)

(defcustom agenda-feeds-work-item-stages
  '(changing built in-review to-push to-publish to-merge)
  "gaffer stages that count as work in flight.
`proposed' is excluded on purpose: gaffer creates one item per review comment,
so including it buries the handful of changes you are carrying under dozens of
one-line comment items.  Those belong in the review queue, not the agenda.
`done' is excluded because it is finished."
  :type '(repeat symbol)
  :group 'agenda-feeds)

(defcustom agenda-feeds-work-item-kinds '(implement-change)
  "gaffer item kinds a work-item feed includes."
  :type '(repeat symbol)
  :group 'agenda-feeds)

(defcustom agenda-feeds-todo-keyword "TODO"
  "The org TODO keyword generated entries are given.
Must be a keyword in `org-todo-keywords', or the entries render as plain
headings and drop out of a TODO agenda.  Left as the universal \"TODO\" rather
than something richer, since a custom keyword set is config, not package
policy."
  :type 'string
  :group 'agenda-feeds)

(defconst agenda-feeds--issue-re "\\b\\([A-Z][A-Z0-9]+-[0-9]+\\)\\b"
  "Regexp matching an issue key such as acme-1234 in an item title.")

(defun agenda-feeds-file (name)
  "Absolute path of feed file NAME under `agenda-feeds-directory'.
Signals if the directory is unset, so a misconfiguration fails loudly at the
point of use rather than writing somewhere surprising."
  (unless agenda-feeds-directory
    (user-error "agenda-feeds: set `agenda-feeds-directory' first"))
  (expand-file-name name (expand-file-name agenda-feeds-directory)))

(defun agenda-feeds--issue-key (title)
  "The issue key mentioned in TITLE, or nil."
  (and (stringp title)
       (string-match agenda-feeds--issue-re title)
       (match-string 1 title)))

(defun agenda-feeds--org-escape (s)
  "S made safe for one line of an org heading."
  (replace-regexp-in-string "[\r\n]+" " " (string-trim (or s ""))))

(defun agenda-feeds--banner (source)
  "Header lines for a feed generated from SOURCE."
  (concat "#+TITLE: " source " (generated)\n"
          "#+FILETAGS: :generated:\n"
          "# GENERATED by agenda-feeds from " source ".\n"
          "# Every refresh rewrites this file whole.  Do not edit it: put\n"
          "# durable notes in your own org files instead.\n\n"))

(defun agenda-feeds--work-items ()
  "gaffer items that count as work in flight, or nil when gaffer is absent."
  (when (and (fboundp 'gaffer--items-read) (boundp 'gaffer--items))
    (gaffer--items-read)
    (seq-filter
     (lambda (it)
       (and (memq (gaffer-item-kind it) agenda-feeds-work-item-kinds)
            (memq (gaffer-item-stage it) agenda-feeds-work-item-stages)
            (not (gaffer-item-deferred it))))
     gaffer--items)))

(defun agenda-feeds--work-item-entry (item)
  "One org TODO entry for gaffer ITEM."
  (let* ((title (agenda-feeds--org-escape (gaffer-item-title item)))
         (repo (gaffer-item-repo item))
         (branch (gaffer-item-branch item))
         (stage (gaffer-item-stage item))
         (pr (gaffer-item-pr-number item))
         (worktree (gaffer-item-worktree item))
         (key (agenda-feeds--issue-key title)))
    (concat
     ;; The issue key becomes a tag as well as staying in the heading, so
     ;; `org-agenda' can filter a whole stack of branches by issue.
     "** " agenda-feeds-todo-keyword " " title
     ;; Org tags cannot contain a hyphen, so acme-1234 tags as acme_1234.
     (if key
         (format "   :%s:" (replace-regexp-in-string "-" "_" key))
       "")
     "\n"
     "   :PROPERTIES:\n"
     (format "   :REPO:     %s\n" (or repo "?"))
     (format "   :BRANCH:   %s\n" (or branch "?"))
     (format "   :STAGE:    %s\n" (or stage "?"))
     (if pr (format "   :PR:       %s#%s\n" (or repo "?") pr) "")
     (if key (format "   :ISSUE:    %s\n" key) "")
     (if worktree (format "   :WORKTREE: %s\n" worktree) "")
     "   :END:\n")))

;;;###autoload
(defun agenda-feeds-work-items ()
  "Write the gaffer work-item feed, and return its file name.
Groups nothing and sorts by stage then repo, so the items closest to landing
read first."
  (interactive)
  (let* ((file (agenda-feeds-file "work-items.org"))
         (items (agenda-feeds--work-items))
         (order (lambda (it)
                  (or (seq-position agenda-feeds-work-item-stages
                                    (gaffer-item-stage it))
                      most-positive-fixnum)))
         (sorted (seq-sort (lambda (a b)
                             (let ((ia (funcall order a))
                                   (ib (funcall order b)))
                               (if (= ia ib)
                                   (string< (or (gaffer-item-repo a) "")
                                            (or (gaffer-item-repo b) ""))
                                 (> ia ib))))
                           items)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert (agenda-feeds--banner "gaffer work items"))
      (insert "* Work in flight\n")
      (if sorted
          (dolist (it sorted) (insert (agenda-feeds--work-item-entry it)))
        (insert "** No items in flight\n")))
    (when (called-interactively-p 'interactive)
      (message "agenda-feeds: %d work item(s) -> %s" (length sorted) file))
    file))

;;;###autoload
(defun agenda-feeds-refresh ()
  "Rewrite every feed whose source is available."
  (interactive)
  (let ((written 0))
    (dolist (feed '(agenda-feeds-work-items))
      (when (ignore-errors (funcall feed) t) (setq written (1+ written))))
    (when (called-interactively-p 'interactive)
      (message "agenda-feeds: refreshed %d feed(s)" written))
    written))

(provide 'agenda-feeds)
;;; agenda-feeds.el ends here
