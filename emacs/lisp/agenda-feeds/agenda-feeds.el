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
;;   * A feed that needs the network fetches SYNCHRONOUSLY, when you ask for
;;     the agenda, and never from a timer.  One key both refreshes and opens,
;;     so a background fetcher would be machinery for a problem nobody has.
;;     The cost is real, though: a blocking fetch in a shared Emacs freezes the
;;     session, so every such feed carries a hard timeout, a size bound, and a
;;     max age that stops a second look paying for a second round trip.
;;
;; Feeds so far:
;;
;;   `agenda-feeds-work-items' -- in-flight branches from the gaffer work-item
;;   store: one TODO per change you are actually carrying, tagged with its Jira
;;   issue where the title names one.
;;
;;   `agenda-feeds-jira' -- issues assigned to you, through quarry.
;;
;;   `agenda-feeds-calendar' -- meetings from any number of iCalendar feeds,
;;   as plain dated headings rather than TODOs, so they land in the day view.
;;
;; Usage:
;;
;;   (setq agenda-feeds-directory "~/lib/notes")
;;   (add-to-list 'org-agenda-files (agenda-feeds-file "work-items.org"))
;;   M-x agenda-feeds-refresh

;;; Code:

(require 'seq)
(require 'subr-x)
;; Local to this package and dependency-free, so requiring it costs nothing and
;; keeps the iCalendar arithmetic testable away from the network.
(require 'agenda-feeds-ics)

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

;; The Jira feed reads through quarry, the Atlassian client.  A library, so a
;; top-level require costs nothing at init and the feed can rely on it being
;; there.
(require 'quarry)

(defvar agenda-feeds-alist
  '((work-items :file "work-items.org" :generator agenda-feeds-work-items)
    (jira       :file "jira.org"       :generator agenda-feeds-jira)
    (calendar   :file "calendar.org"   :generator agenda-feeds-calendar))
  "Feeds `agenda-feeds-refresh' visits, in order.
Each entry is (NAME :file BASENAME :generator FUNCTION).  A generator whose
function is not `fboundp' is skipped, so a feed whose source package is absent
costs nothing.")

(defcustom agenda-feeds-max-ages
  '((work-items . 0)
    (jira . 600)
    (calendar . 600))
  "Seconds each feed's file stays fresh, by feed name.  0 refreshes every time.
This is what lets one key both open the agenda and keep it current without
re-fetching on every press.  A feed built from local state costs nothing and
wants 0; a feed that makes a network round trip wants a bound, so opening the
agenda twice in a minute does not pay for it twice.  A feed with no entry here
is treated as 0."
  :type '(alist :key-type symbol :value-type integer)
  :group 'agenda-feeds)

(defcustom agenda-feeds-calendars nil
  "Calendars the calendar feed reads, as an alist of (NAME . URL).
NAME is a short symbol, used as the org tag on that calendar's events.  URL is
an address serving iCalendar text, or a function of no arguments returning one.

Prefer the function form.  A calendar's private address is a credential -- it
grants anyone holding it read access to the calendar -- so it belongs in a
password store rather than in this variable, in your init file, or in a shell
history.  It is never written to the feed file or named in an error:

  (setq agenda-feeds-calendars
        (list (cons \\='google
                    (lambda () (auth-source-pass-get \\='secret
                                                     \"calendar/google\")))))"
  :type '(alist :key-type symbol :value-type (choice string function))
  :group 'agenda-feeds)

(defcustom agenda-feeds-calendar-days 14
  "Days from today the calendar feed covers.
The day view needs only today, but the agenda is also read forward, and one
fetch covering a fortnight costs no more than one covering a day."
  :type 'integer
  :group 'agenda-feeds)

(defcustom agenda-feeds-calendar-timeout 20
  "Seconds the calendar feed waits for a calendar to answer.
This fetch is synchronous and runs when you ask for the agenda, so the timeout
is the only thing standing between a slow server and a frozen Emacs.  On expiry
the feed fails and its previous file is kept."
  :type 'integer
  :group 'agenda-feeds)

(defcustom agenda-feeds-calendar-max-bytes (* 8 1024 1024)
  "Largest calendar response the feed will parse.
A calendar is someone else's file and can be arbitrarily large; a year of a busy
work calendar already runs to a megabyte.  Refusing an oversized one keeps a
runaway feed from wedging the session it was fetched from."
  :type 'integer
  :group 'agenda-feeds)

(defcustom agenda-feeds-calendar-max-events 500
  "Most events the calendar feed will write.
Reaching this says so in the file and in a message, since a silently truncated
agenda reads exactly like a quiet one."
  :type 'integer
  :group 'agenda-feeds)

(defcustom agenda-feeds-jira-jql
  "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
  "JQL selecting the issues the Jira feed lists."
  :type 'string
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
  "Regexp matching an issue key (capitals, hyphen, digits) in an item title.")

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

(defconst agenda-feeds--timestamp-re
  "<\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}[^>\n]*\\)>"
  "An active org timestamp, which a source's text must not be able to forge.")

(defun agenda-feeds--org-escape (s)
  "S made safe for one line of an org heading.
Newlines collapse to spaces, so text from a source cannot open a heading or a
drawer of its own.  A date in angle brackets is turned into parentheses for the
same reason: org reads an active timestamp anywhere in an entry, so a title
carrying one would put the entry on that day as well as its real one."
  (replace-regexp-in-string
   agenda-feeds--timestamp-re "(\\1)"
   (replace-regexp-in-string "[\r\n]+" " " (string-trim (or s "")))))

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
     (if key (format "   :%s:" (agenda-feeds--issue-tag key)) "")
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

(defun agenda-feeds--issue-tag (key)
  "KEY as an org tag.
Org tags cannot contain a hyphen, so a key's hyphen becomes an underscore."
  (replace-regexp-in-string "-" "_" key))

;;;###autoload
(defun agenda-feeds-jira ()
  "Write the Jira feed from `agenda-feeds-jira-jql', and return its file name.
Reads through quarry, so it needs no credential of its own.  This makes a
synchronous network call: it is meant to run when you ask for the agenda, never
from a timer."
  (interactive)
  (let ((file (agenda-feeds-file "jira.org"))
        (issues (quarry-jira-search agenda-feeds-jira-jql)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert (agenda-feeds--banner "Jira"))
      (insert "* Assigned issues\n")
      (if issues
          (dolist (is issues)
            (let ((key (plist-get is :key)))
              (insert
               ;; A link, so C-c C-o from the agenda opens the issue.
               (format "** %s [[%s][%s]] %s   :%s:\n"
                       agenda-feeds-todo-keyword
                       (plist-get is :url) key
                       (agenda-feeds--org-escape (plist-get is :summary))
                       (agenda-feeds--issue-tag key))
               "   :PROPERTIES:\n"
               (format "   :ISSUE:   %s\n" key)
               (format "   :STATUS:  %s\n" (or (plist-get is :status) "?"))
               (format "   :UPDATED: %s\n" (or (plist-get is :updated) "?"))
               "   :END:\n")))
        (insert "** No assigned issues\n")))
    (when (called-interactively-p 'interactive)
      (message "agenda-feeds: %d Jira issue(s) -> %s" (length issues) file))
    file))

(defun agenda-feeds--day-start (time)
  "Midnight, local, at the start of TIME's day."
  (let ((d (decode-time time)))
    (encode-time (list 0 0 0 (decoded-time-day d) (decoded-time-month d)
                       (decoded-time-year d) nil -1 (decoded-time-zone d)))))

(defun agenda-feeds--org-stamp (start end all-day)
  "An org timestamp covering START to END, as a date range if ALL-DAY."
  (let ((day "%Y-%m-%d %a"))
    (cond
     (all-day
      (let ((from (format-time-string day start))
            (to (format-time-string day end)))
        (if (equal from to)
            (format "<%s>" from)
          (format "<%s>--<%s>" from to))))
     ((equal (format-time-string "%Y-%m-%d" start)
             (format-time-string "%Y-%m-%d" end))
      ;; Org's own one-line form for a meeting, which the agenda renders as a
      ;; time range rather than as two separate entries.
      (format "<%s %s-%s>" (format-time-string day start)
              (format-time-string "%H:%M" start)
              (format-time-string "%H:%M" end)))
     (t (format "<%s %s>--<%s %s>"
                (format-time-string day start)
                (format-time-string "%H:%M" start)
                (format-time-string day end)
                (format-time-string "%H:%M" end))))))

(defun agenda-feeds--calendar-tag (name)
  "NAME as an org tag.
Org tags allow only word characters, so anything else becomes an underscore."
  (replace-regexp-in-string "[^[:alnum:]_@#%]" "_" (format "%s" name)))

(defun agenda-feeds--calendar-fetch (name url)
  "The iCalendar text calendar NAME serves at URL.
Errors name only NAME: URL is a credential, so it must not reach a message, an
error, or the feed file."
  (require 'url)
  (let ((buffer (condition-case err
                    (url-retrieve-synchronously
                     url t t agenda-feeds-calendar-timeout)
                  ;; The signal data can quote the URL, so only the symbol is
                  ;; reported.
                  (error (error "agenda-feeds: %s fetch failed (%s)"
                                name (car err))))))
    (unless buffer
      (error "agenda-feeds: %s did not answer in %ds"
             name agenda-feeds-calendar-timeout))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (let ((status (and (re-search-forward "\\`HTTP/[0-9.]+ +\\([0-9]+\\)"
                                                nil t)
                             (string-to-number (match-string 1)))))
            (unless (eq status 200)
              (error "agenda-feeds: %s returned HTTP %s" name (or status "?")))
            (when (> (buffer-size) agenda-feeds-calendar-max-bytes)
              (error "agenda-feeds: %s sent %d bytes, over the %d limit"
                     name (buffer-size) agenda-feeds-calendar-max-bytes))
            (search-forward "\n\n" nil 'move)
            (decode-coding-string
             (buffer-substring-no-properties (point) (point-max)) 'utf-8)))
      (kill-buffer buffer))))

(defun agenda-feeds--calendar-entry (name event)
  "One org entry for EVENT, read from calendar NAME.
Deliberately not a TODO: a meeting is not a task, and as a plain dated heading
it lands in the agenda's day view instead of the work-in-flight block."
  (let ((summary (agenda-feeds--org-escape (plist-get event :summary)))
        (location (agenda-feeds--org-escape (plist-get event :location))))
    (concat
     "** " summary "   :" (agenda-feeds--calendar-tag name) ":\n"
     "   " (agenda-feeds--org-stamp (plist-get event :start)
                                    (plist-get event :end)
                                    (plist-get event :all-day))
     "\n"
     (if (string-empty-p location)
         ""
       (concat "   :PROPERTIES:\n"
               "   :LOCATION: " location "\n"
               "   :END:\n")))))

;;;###autoload
(defun agenda-feeds-calendar ()
  "Write the calendar feed from `agenda-feeds-calendars', and return its file.
Fetches each calendar synchronously, so it is meant to run when you ask for the
agenda and never from a timer.

One calendar failing fails the whole feed, which keeps the previous file rather
than writing a partial one.  All the calendars share a file, so a half-written
one would show today's meetings from one calendar and none from another while
looking complete -- the failure mode this package exists to avoid."
  (interactive)
  (let* ((file (agenda-feeds-file "calendar.org"))
         (start (agenda-feeds--day-start (current-time)))
         (end (time-add start (* 86400 (max 1 agenda-feeds-calendar-days))))
         (events nil)
         (failures nil))
    (dolist (entry agenda-feeds-calendars)
      (let* ((name (car entry))
             (provider (cdr entry))
             (url (if (functionp provider) (funcall provider) provider)))
        (condition-case err
            (progn
              (unless (and (stringp url) (not (string-empty-p url)))
                (error "agenda-feeds: %s has no URL" name))
              (dolist (event (agenda-feeds-ics-events
                              (agenda-feeds--calendar-fetch name url)
                              start end))
                (push (cons name event) events)))
          (error (push (error-message-string err) failures)))))
    ;; Every calendar is tried before failing, so one message names them all.
    (when failures
      (error "%s" (string-join (nreverse failures) "; ")))
    (setq events (sort (nreverse events)
                       (lambda (a b) (time-less-p (plist-get (cdr a) :start)
                                                  (plist-get (cdr b) :start)))))
    (let* ((total (length events))
           (shown (min total agenda-feeds-calendar-max-events))
           (kept (seq-take events shown)))
      (make-directory (file-name-directory file) t)
      (with-temp-file file
        (insert (agenda-feeds--banner "Calendars"))
        (insert (format "* Next %d day(s)\n" agenda-feeds-calendar-days))
        (when (> total shown)
          (insert (format "** TRUNCATED: %d of %d events shown\n"
                          shown total)))
        (if kept
            (dolist (row kept)
              (insert (agenda-feeds--calendar-entry (car row) (cdr row))))
          (insert (if agenda-feeds-calendars
                      "** No events in the window\n"
                    "** No calendars configured\n"))))
      (when (called-interactively-p 'interactive)
        (message "agenda-feeds: %d calendar event(s)%s -> %s"
                 shown
                 (if (> total shown) (format " of %d, TRUNCATED" total) "")
                 file))
      file)))

(defun agenda-feeds--stale-p (name file)
  "Non-nil if FILE should be regenerated for feed NAME.
Missing counts as stale, and a max age of 0 or less means always."
  (let ((max-age (or (alist-get name agenda-feeds-max-ages) 0)))
    (or (not (file-exists-p file))
        (<= max-age 0)
        (> (float-time
            (time-since (file-attribute-modification-time
                         (file-attributes file))))
           max-age))))

;;;###autoload
(defun agenda-feeds-refresh (&optional force)
  "Regenerate each stale feed in `agenda-feeds-alist'.
With FORCE (a prefix argument), regenerate every feed regardless of age.

A generator that fails is reported and skipped, leaving its previous file in
place: an agenda showing yesterday's Jira is far better than one that lost it."
  (interactive "P")
  (let ((written 0) (fresh 0) (skipped 0) (failed 0))
    (dolist (entry agenda-feeds-alist)
      (let* ((name (car entry))
             (spec (cdr entry))
             (generator (plist-get spec :generator))
             (file (agenda-feeds-file (plist-get spec :file))))
        (cond
         ((not (fboundp generator)) (setq skipped (1+ skipped)))
         ((and (not force) (not (agenda-feeds--stale-p name file)))
          (setq fresh (1+ fresh)))
         (t
          (condition-case err
              (progn (funcall generator) (setq written (1+ written)))
            (error
             (setq failed (1+ failed))
             (message "agenda-feeds: %s failed, keeping previous file: %s"
                      name (error-message-string err))))))))
    (when (called-interactively-p 'interactive)
      (message
       "agenda-feeds: %d written, %d still fresh, %d unavailable, %d failed"
       written fresh skipped failed))
    (list :written written :fresh fresh :skipped skipped :failed failed)))

(provide 'agenda-feeds)
;;; agenda-feeds.el ends here
