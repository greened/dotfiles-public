;;; agenda-feeds-ics.el --- Read iCalendar text into dated events -*- lexical-binding: t; -*-

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
;; Turns iCalendar (RFC 5545) text into the events that fall inside a date
;; window.  Text in, events out: no network, no org, no state, which is what
;; makes the awkward half of a calendar feed testable on its own.
;;
;; Why not `icalendar.el', which ships with Emacs: recurring meetings are most
;; of a work calendar, and what a feed needs is a rule expanded into the
;; occurrences landing in a given window.  `icalendar.el' is built to import a
;; file into a diary once, and turns an RRULE into a diary sexp rather than
;; into dates, so the expansion would still have to be written here.
;;
;; What it reads, which is what a calendar server sends in practice:
;;
;;   * folded lines, escaped TEXT values, and property parameters
;;   * DTSTART/DTEND as UTC, as a zoned local time, or as an all-day date
;;   * DTEND absent, supplied by DURATION or by the RFC's defaults
;;   * RRULE FREQ=DAILY/WEEKLY/MONTHLY/YEARLY with INTERVAL, COUNT, UNTIL,
;;     BYDAY (weekly) and BYMONTHDAY (monthly)
;;   * EXDATE exclusions, and a RECURRENCE-ID event overriding one occurrence
;;     of its own series
;;   * STATUS:CANCELLED, dropped
;;
;; TODO limitations.  Each one fails toward showing an event rather than hiding
;; one, so the cost is a stray line in the agenda and never a missed meeting:
;;
;;   * BYDAY with an ordinal ("2TU", the second Tuesday) is not expanded; such
;;     a series keeps its DTSTART day-of-month instead.
;;   * BYSETPOS, BYWEEKNO and BYYEARDAY are ignored.
;;   * WKST is taken as Monday, which shows only in a weekly rule whose
;;     INTERVAL exceeds one.
;;   * VTIMEZONE is not read.  A TZID goes to `encode-time', which knows the
;;     zone names a server sends; an unrecognised one falls back to local time
;;     rather than failing the whole feed.
;;   * An attendee's own PARTSTAT is not consulted, so a meeting you declined
;;     still appears.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'time-date)

(defconst agenda-feeds-ics-max-periods 4000
  "Most recurrence periods `agenda-feeds-ics-events' will step through.
A rule is expanded from its DTSTART rather than from the window, because COUNT
counts occurrences from the start of the series and cannot be honoured from the
middle.  A daily meeting started ten years ago is therefore a few thousand
steps, and a malformed rule could be unbounded, so the walk is capped.  Reaching
the cap truncates one series and leaves the rest of the feed intact.")

(defconst agenda-feeds-ics--weekdays
  '(("SU" . 0) ("MO" . 1) ("TU" . 2) ("WE" . 3) ("TH" . 4) ("FR" . 5)
    ("SA" . 6))
  "iCalendar weekday abbreviations and their `decoded-time-weekday' numbers.")

;;; Lexing

(defun agenda-feeds-ics--unfold (text)
  "TEXT with iCalendar line folding undone.
A long property is split across lines by inserting a break and one space or
tab, so the continuation must be rejoined before anything is parsed."
  (replace-regexp-in-string "\r?\n[ \t]" "" text))

(defun agenda-feeds-ics--unescape (value)
  "VALUE with the escapes an iCalendar TEXT value uses resolved."
  (let ((out "") (i 0) (n (length value)))
    (while (< i n)
      (let ((c (aref value i)))
        (if (and (eq c ?\\) (< (1+ i) n))
            (let ((next (aref value (1+ i))))
              (setq out (concat out (pcase next
                                      ((or ?n ?N) "\n")
                                      (_ (char-to-string next))))
                    i (+ i 2)))
          (setq out (concat out (char-to-string c))
                i (1+ i)))))
    out))

(defun agenda-feeds-ics--split-params (spec)
  "Parse SPEC, a property name with parameters, into (NAME . ALIST).
SPEC is the part before the colon, so \"DTSTART;TZID=UTC\" yields
\(\"DTSTART\" (\"TZID\" . \"UTC\"))."
  (let* ((parts (split-string spec ";"))
         (name (upcase (car parts)))
         (params
          (delq nil
                (mapcar (lambda (p)
                          (when (string-match "\\`\\([^=]+\\)=\\(.*\\)\\'" p)
                            (cons (upcase (match-string 1 p))
                                  ;; A parameter value may be quoted, as a
                                  ;; TZID containing a colon must be.
                                  (string-trim (match-string 2 p) "\"" "\""))))
                        (cdr parts)))))
    (cons name params)))

(defun agenda-feeds-ics--properties (lines)
  "Parse LINES into a list of (NAME PARAMS VALUE)."
  (delq nil
        (mapcar
         (lambda (line)
           (when (string-match "\\`\\([^:]+\\):\\(.*\\)\\'" line)
             ;; Both halves are taken BEFORE parsing the parameters, which
             ;; matches internally and would otherwise overwrite the match
             ;; data -- silently, and only for a property that has parameters.
             (let* ((spec (match-string 1 line))
                    (value (match-string 2 line))
                    (parsed (agenda-feeds-ics--split-params spec)))
               (list (car parsed) (cdr parsed) value))))
         lines)))

(defun agenda-feeds-ics--blocks (text component)
  "Property lists for each COMPONENT block in TEXT.
COMPONENT is a name such as \"VEVENT\"; nested blocks are not descended into,
which is what keeps a VALARM's own DTSTART out of its event."
  (let ((begin (concat "BEGIN:" component))
        (end (concat "END:" component))
        (depth 0) (current nil) (blocks nil))
    (dolist (line (split-string (agenda-feeds-ics--unfold text) "\r?\n" t))
      (let ((line (string-trim-right line)))
        (cond
         ((equal line begin) (setq depth 1 current nil))
         ((and (= depth 1) (equal line end))
          (push (agenda-feeds-ics--properties (nreverse current)) blocks)
          (setq depth 0 current nil))
         ((and (= depth 1) (string-prefix-p "BEGIN:" line)) (setq depth 2))
         ((and (= depth 2) (string-prefix-p "END:" line)) (setq depth 1))
         ((= depth 1) (push line current)))))
    (nreverse blocks)))

(defun agenda-feeds-ics--get (props name)
  "The (NAME PARAMS VALUE) entry for NAME in PROPS, or nil."
  (seq-find (lambda (p) (equal (car p) name)) props))

(defun agenda-feeds-ics--value (props name)
  "The unescaped value of NAME in PROPS, or nil."
  (let ((entry (agenda-feeds-ics--get props name)))
    (and entry (agenda-feeds-ics--unescape (nth 2 entry)))))

;;; Times

(defun agenda-feeds-ics--num (s from to)
  "The number in S between FROM and TO, or 0 if S is too short."
  (if (>= (length s) to) (string-to-number (substring s from to)) 0))

(defun agenda-feeds-ics--encode (sec min hour day month year zone)
  "Encode a time, falling back to local time when ZONE is not recognised.
An unknown TZID must not take the whole feed down, and being an hour out is a
better failure than an empty agenda."
  (condition-case nil
      (encode-time (list sec min hour day month year nil -1 zone))
    (error (encode-time (list sec min hour day month year nil -1 nil)))))

(defun agenda-feeds-ics--parse-time (value params)
  "Parse VALUE, an iCalendar date or date-time, with its PARAMS.
Returns a plist with :time and :all-day."
  (let* ((tzid (cdr (assoc "TZID" params)))
         (date-p (or (equal (cdr (assoc "VALUE" params)) "DATE")
                     (not (string-match-p "T" value))))
         (year (agenda-feeds-ics--num value 0 4))
         (month (agenda-feeds-ics--num value 4 6))
         (day (agenda-feeds-ics--num value 6 8)))
    (if date-p
        (list :time (agenda-feeds-ics--encode 0 0 0 day month year nil)
              :all-day t)
      (let ((zone (cond ((string-suffix-p "Z" value) 0) (tzid tzid) (t nil))))
        (list :time (agenda-feeds-ics--encode
                     (agenda-feeds-ics--num value 13 15)
                     (agenda-feeds-ics--num value 11 13)
                     (agenda-feeds-ics--num value 9 11)
                     day month year zone)
              :all-day nil)))))

(defun agenda-feeds-ics--parse-duration (s)
  "Seconds in S, an iCalendar duration such as \"PT1H30M\" or \"P2D\"."
  (let ((total 0) (sign (if (string-prefix-p "-" s) -1 1)) (start 0))
    (while (string-match "\\([0-9]+\\)\\([WDHMS]\\)" s start)
      (let ((n (string-to-number (match-string 1 s))))
        (setq total (+ total (* n (pcase (match-string 2 s)
                                    ("W" 604800) ("D" 86400) ("H" 3600)
                                    ("M" 60) (_ 1))))
              start (match-end 0))))
    (* sign total)))

(defun agenda-feeds-ics--times (props)
  "Start and end of the event described by PROPS.
Returns a plist with :start, :end and :all-day, where an all-day :end is the
INCLUSIVE last day rather than the exclusive DTEND the RFC carries -- the org
writer wants the day it should print."
  (let* ((dtstart (agenda-feeds-ics--get props "DTSTART"))
         (dtend (agenda-feeds-ics--get props "DTEND"))
         (duration (agenda-feeds-ics--value props "DURATION")))
    (when dtstart
      (let* ((start (agenda-feeds-ics--parse-time (nth 2 dtstart)
                                                  (nth 1 dtstart)))
             (all-day (plist-get start :all-day))
             (from (plist-get start :time))
             (to (cond
                  (dtend (plist-get (agenda-feeds-ics--parse-time
                                     (nth 2 dtend) (nth 1 dtend))
                                    :time))
                  (duration (time-add from (agenda-feeds-ics--parse-duration
                                            duration)))
                  ;; RFC 5545: with neither, an all-day event covers one day
                  ;; and a timed one has no duration.
                  (all-day (time-add from 86400))
                  (t from))))
        (list :start from
              :end (if all-day (time-subtract to 86400) to)
              :all-day all-day)))))

;;; Recurrence

(defun agenda-feeds-ics--parse-rrule (s)
  "Parse S, an RRULE value, into a plist."
  (let (out)
    (dolist (part (split-string s ";" t))
      (when (string-match "\\`\\([^=]+\\)=\\(.*\\)\\'" part)
        (let ((key (upcase (match-string 1 part)))
              (val (match-string 2 part)))
          (pcase key
            ("FREQ" (setq out (plist-put out :freq (intern (downcase val)))))
            ("INTERVAL"
             (setq out (plist-put out :interval
                                  (max 1 (string-to-number val)))))
            ("COUNT" (setq out (plist-put out :count (string-to-number val))))
            ("UNTIL"
             (setq out (plist-put out :until
                                  (plist-get (agenda-feeds-ics--parse-time
                                              val nil)
                                             :time))))
            ("BYDAY"
             (setq out (plist-put
                        out :byday
                        ;; An ordinal prefix ("2TU") is dropped rather than
                        ;; honoured; see the TODO limitations.
                        (delq nil
                              (mapcar
                               (lambda (d)
                                 (let ((day (substring
                                             d (max 0 (- (length d) 2)))))
                                   (cdr (assoc day
                                               agenda-feeds-ics--weekdays))))
                               (split-string val "," t))))))
            ("BYMONTHDAY"
             (setq out (plist-put out :bymonthday
                                  (mapcar #'string-to-number
                                          (split-string val "," t)))))))))
    out))

(defun agenda-feeds-ics--at (decoded day month year)
  "DECODED moved to DAY MONTH YEAR, keeping its time of day.
Returns nil when that date does not exist, which is how the RFC says to treat
the 31st of a short month."
  (if (or (< day 1) (> day (date-days-in-month year month)))
      nil
    (agenda-feeds-ics--encode (decoded-time-second decoded)
                              (decoded-time-minute decoded)
                              (decoded-time-hour decoded)
                              day month year
                              (decoded-time-zone decoded))))

(defun agenda-feeds-ics--week-start (time)
  "The Monday of TIME's week, at TIME's time of day."
  (let* ((d (decode-time time))
         (dow (decoded-time-weekday d)))
    (time-add time (* -86400 (mod (+ dow 6) 7)))))

(defun agenda-feeds-ics--period-starts (rule start &optional skip)
  "A function yielding successive period starts for RULE from START.
Each call returns the next one, so a series is walked without building it.
SKIP begins that many periods in, which is only sound when the caller has
established the skipped ones cannot matter."
  (let ((freq (plist-get rule :freq))
        (interval (or (plist-get rule :interval) 1))
        (n (1- (or skip 0))))
    (lambda ()
      (setq n (1+ n))
      (let ((k (* n interval)))
        (pcase freq
          ('daily (time-add start (* k 86400)))
          ('weekly (time-add start (* k 604800)))
          ('monthly
           (let* ((d (decode-time start))
                  (m (+ (decoded-time-month d) k))
                  (year (+ (decoded-time-year d) (/ (1- m) 12)))
                  (month (1+ (mod (1- m) 12))))
             ;; A period whose day-of-month does not exist yields nil and is
             ;; skipped, without stopping the walk.
             (list :year year :month month :decoded d)))
          ('yearly
           (let ((d (decode-time start)))
             (list :year (+ (decoded-time-year d) k)
                   :month (decoded-time-month d)
                   :decoded d)))
          (_ nil))))))

(defun agenda-feeds-ics--period-occurrences (rule period)
  "Occurrence times contributed by PERIOD of RULE.
PERIOD is a time for a daily or weekly rule, and a plist naming a year and
month for a monthly or yearly one.  A weekly rule's week can open before the
series does, so the caller drops anything earlier than DTSTART."
  (let ((freq (plist-get rule :freq))
        (byday (plist-get rule :byday))
        (bymonthday (plist-get rule :bymonthday)))
    (pcase freq
      ('weekly
       (if (null byday)
           (list period)
         (let ((monday (agenda-feeds-ics--week-start period)))
           (mapcar (lambda (dow)
                     (time-add monday (* 86400 (mod (+ dow 6) 7))))
                   (sort (copy-sequence byday) #'<)))))
      ((or 'monthly 'yearly)
       (let* ((decoded (plist-get period :decoded))
              (year (plist-get period :year))
              (month (plist-get period :month))
              (days (or (and (eq freq 'monthly) bymonthday)
                        (list (decoded-time-day decoded)))))
         (delq nil (mapcar (lambda (day)
                             (agenda-feeds-ics--at decoded day month year))
                           (sort (copy-sequence days) #'<)))))
      (_ (list period)))))

(defun agenda-feeds-ics--ended-p (rule start win-start)
  "Non-nil when RULE from START certainly ends before WIN-START.
Only certainties count: a rule this cannot rule out is expanded as usual."
  (let ((until (plist-get rule :until))
        (count (plist-get rule :count))
        (freq (plist-get rule :freq))
        (interval (or (plist-get rule :interval) 1)))
    (cond
     ((and until (time-less-p until win-start)) t)
     ;; With BYDAY a week contributes several occurrences, so COUNT does not
     ;; map onto periods and the series end cannot be computed this way.
     ((and count (null (plist-get rule :byday)) (memq freq '(daily weekly)))
      (let ((step (* (if (eq freq 'daily) 86400 604800) interval)))
        (time-less-p (time-add start (* step (1- (max 1 count)))) win-start)))
     (t nil))))

(defun agenda-feeds-ics--skip (rule start win-start)
  "Periods of RULE from START that can be skipped to reach WIN-START.
Zero when the rule carries a COUNT, since that has to be counted from the
series start and cannot be honoured from the middle.

This is what makes the reader usable interactively rather than a correctness
matter.  Walking every series from its DTSTART took 4.3 seconds over a real
1225-event calendar -- a visible freeze on a keypress that both refreshes the
feeds and opens the agenda.  Nearly all of it went on occurrences years before
the window.  One period is given back for safety, so a weekly period that
opens before the window but still reaches into it is not skipped."
  (let ((freq (plist-get rule :freq))
        (interval (or (plist-get rule :interval) 1)))
    (if (plist-get rule :count)
        0
      (let ((delta (float-time (time-subtract win-start start))))
        (if (<= delta 0)
            0
          (max 0
               (1- (pcase freq
                     ('daily (floor delta (* 86400 interval)))
                     ('weekly (floor delta (* 604800 interval)))
                     ((or 'monthly 'yearly)
                      (let* ((a (decode-time start))
                             (b (decode-time win-start))
                             (months
                              (+ (* 12 (- (decoded-time-year b)
                                          (decoded-time-year a)))
                                 (- (decoded-time-month b)
                                    (decoded-time-month a)))))
                        (max 0 (floor (if (eq freq 'monthly)
                                          months
                                        (/ months 12))
                                      interval))))
                     (_ 0)))))))))

(defun agenda-feeds-ics--expand (rule start win-start win-end excluded)
  "Occurrences of RULE from START that fall between WIN-START and WIN-END.
EXCLUDED is a list of times no occurrence may land on, which carries both
EXDATE and the instances a RECURRENCE-ID event has taken over."
  (if (agenda-feeds-ics--ended-p rule start win-start)
      nil
    (agenda-feeds-ics--walk rule start win-start win-end excluded)))

(defun agenda-feeds-ics--walk (rule start win-start win-end excluded)
  "Step RULE from START, collecting occurrences between WIN-START and WIN-END.
EXCLUDED is as for `agenda-feeds-ics--expand'."
  (let ((next (agenda-feeds-ics--period-starts
               rule start (agenda-feeds-ics--skip rule start win-start)))
        (until (plist-get rule :until))
        (count (plist-get rule :count))
        (emitted 0) (periods 0) (done nil) (out nil))
    (while (not done)
      (let ((period (funcall next)))
        (setq periods (1+ periods))
        (cond
         ((or (null period) (> periods agenda-feeds-ics-max-periods))
          (setq done t))
         (t
          (dolist (time (agenda-feeds-ics--period-occurrences rule period))
            (unless done
              (cond
               ;; The first period may open before DTSTART, as a weekly BYDAY
               ;; rule's week does; those days are not occurrences.
               ((time-less-p time start) nil)
               ((and until (time-less-p until time)) (setq done t))
               ((and count (>= emitted count)) (setq done t))
               (t
                (setq emitted (1+ emitted))
                (when (and (not (time-less-p time win-start))
                           (not (time-less-p win-end time))
                           (not (seq-find (lambda (x) (time-equal-p x time))
                                          excluded)))
                  (push time out))))))
          ;; Stepping past the window is the ordinary way out, but only once
          ;; the period itself is past it: a weekly period starts on Monday
          ;; and can still contribute a later weekday.
          (let ((probe (if (listp period)
                           (agenda-feeds-ics--at (plist-get period :decoded)
                                                 1
                                                 (plist-get period :month)
                                                 (plist-get period :year))
                         period)))
            (when (and probe (time-less-p win-end probe)
                       (not (eq (plist-get rule :freq) 'weekly)))
              (setq done t))
            (when (and probe (eq (plist-get rule :freq) 'weekly)
                       (time-less-p win-end (time-add probe 604800)))
              (setq done t)))))))
    (nreverse out)))

;;; Events

(defun agenda-feeds-ics--exdates (props)
  "Times listed in the EXDATE properties of PROPS."
  (let (out)
    (dolist (p props)
      (when (equal (car p) "EXDATE")
        (dolist (v (split-string (nth 2 p) "," t))
          (push (plist-get (agenda-feeds-ics--parse-time v (nth 1 p)) :time)
                out))))
    (nreverse out)))

(defun agenda-feeds-ics--event (props time all-day duration)
  "An event plist for PROPS occurring at TIME.
ALL-DAY and DURATION come from the series, so every occurrence is as long as
the one DTSTART/DTEND described."
  (list :uid (agenda-feeds-ics--value props "UID")
        :summary (or (agenda-feeds-ics--value props "SUMMARY") "(no title)")
        :location (agenda-feeds-ics--value props "LOCATION")
        :start time
        :end (time-add time duration)
        :all-day all-day))

(defun agenda-feeds-ics-events (text win-start win-end)
  "Events in TEXT that fall between WIN-START and WIN-END, sorted by start.
An event is a plist with :uid, :summary, :location, :start, :end and :all-day.
A recurring event contributes one entry per occurrence in the window, and an
all-day :end is the inclusive last day."
  (let* ((blocks (agenda-feeds-ics--blocks text "VEVENT"))
         (live (seq-remove (lambda (props)
                             (equal (agenda-feeds-ics--value props "STATUS")
                                    "CANCELLED"))
                           blocks))
         (overrides (seq-filter (lambda (props)
                                  (agenda-feeds-ics--get props "RECURRENCE-ID"))
                                live))
         (bases (seq-remove (lambda (props)
                              (agenda-feeds-ics--get props "RECURRENCE-ID"))
                            live))
         ;; Overrides are indexed by UID once.  Scanning the whole override
         ;; list per base is a cross product, and on a real calendar -- 1225
         ;; events, 100 of them overrides -- that was 122500 time parses and
         ;; the bulk of a four-second refresh.
         (overrides-by-uid
          (let ((table (make-hash-table :test #'equal)))
            (dolist (props overrides)
              (let ((rid (agenda-feeds-ics--get props "RECURRENCE-ID"))
                    (uid (agenda-feeds-ics--value props "UID")))
                (push (plist-get (agenda-feeds-ics--parse-time
                                  (nth 2 rid) (nth 1 rid))
                                 :time)
                      (gethash uid table))))
            table))
         (out nil))
    ;; An override replaces one occurrence of its series, so the base must not
    ;; also emit that instance -- otherwise a moved meeting shows up twice, at
    ;; both its old time and its new one.
    (dolist (props bases)
      (let ((times (agenda-feeds-ics--times props)))
        (when times
          (let* ((start (plist-get times :start))
                 (all-day (plist-get times :all-day))
                 (duration (float-time (time-subtract (plist-get times :end)
                                                      start)))
                 (uid (agenda-feeds-ics--value props "UID"))
                 (rrule (agenda-feeds-ics--value props "RRULE"))
                 (taken (append (agenda-feeds-ics--exdates props)
                                (gethash uid overrides-by-uid))))
            (if rrule
                (dolist (time (agenda-feeds-ics--expand
                               (agenda-feeds-ics--parse-rrule rrule)
                               start win-start win-end taken))
                  (push (agenda-feeds-ics--event props time all-day duration)
                        out))
              (when (and (not (time-less-p (plist-get times :end) win-start))
                         (not (time-less-p win-end start))
                         (not (seq-find (lambda (x) (time-equal-p x start))
                                        taken)))
                (push (agenda-feeds-ics--event props start all-day duration)
                      out)))))))
    (dolist (props overrides)
      (let ((times (agenda-feeds-ics--times props)))
        (when (and times
                   (not (time-less-p (plist-get times :end) win-start))
                   (not (time-less-p win-end (plist-get times :start))))
          (push (agenda-feeds-ics--event
                 props (plist-get times :start) (plist-get times :all-day)
                 (float-time (time-subtract (plist-get times :end)
                                            (plist-get times :start))))
                out))))
    (sort out (lambda (a b) (time-less-p (plist-get a :start)
                                         (plist-get b :start))))))

(provide 'agenda-feeds-ics)
;;; agenda-feeds-ics.el ends here
