;;; agenda-feeds-ics-tests.el --- Tests for the iCalendar reader -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Run with ../check.sh, which is what CI-by-hand looks like here.
;;
;; Every fixture is written inline as iCalendar text, since the reader's whole
;; job is turning that text into dates.  Times are given with an explicit TZID
;; or as UTC wherever the assertion depends on the clock, so the suite does not
;; pass or fail according to the machine's zone.

;;; Code:

(require 'ert)
(require 'agenda-feeds-ics)

(defun aft--ics (&rest lines)
  "Wrap LINES in a VCALENDAR, joined with CRLF as a server sends them."
  (mapconcat #'identity
             (append '("BEGIN:VCALENDAR" "VERSION:2.0")
                     lines
                     '("END:VCALENDAR"))
             "\r\n"))

(defun aft--utc (year month day hour minute)
  "The time at YEAR MONTH DAY HOUR MINUTE UTC."
  (encode-time (list 0 minute hour day month year nil -1 0)))

(defun aft--summaries (events)
  "The :summary of each event in EVENTS."
  (mapcar (lambda (e) (plist-get e :summary)) events))

(defun aft--starts (events)
  "The :start of each event in EVENTS, as \"YYYY-MM-DD HH:MM\" in UTC."
  (mapcar (lambda (e)
            (format-time-string "%Y-%m-%d %H:%M" (plist-get e :start) t))
          events))

;;; Lexing

(ert-deftest aft-unfolds-a-continued-line ()
  "A property split across lines is rejoined before it is parsed.
Unfolding drops the break AND the space that follows it, per RFC 5545, so the
first line here keeps the space that belongs to the text."
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20260902T140000Z" "DTEND:20260902T150000Z"
                           "SUMMARY:a very long title that the "
                           " server folded here"
                           "END:VEVENT")
                 (aft--utc 2026 9 1 0 0) (aft--utc 2026 9 3 0 0))))
    (should (equal (aft--summaries events)
                   '("a very long title that the server folded here")))))

(ert-deftest aft-unescapes-text-values ()
  "Escaped commas, semicolons and newlines come back as themselves."
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20260902T140000Z" "DTEND:20260902T150000Z"
                           "SUMMARY:review\\, then\\; ship\\nsoon"
                           "END:VEVENT")
                 (aft--utc 2026 9 1 0 0) (aft--utc 2026 9 3 0 0))))
    (should (equal (aft--summaries events) '("review, then; ship\nsoon")))))

(ert-deftest aft-ignores-a-nested-component ()
  "A VALARM's own trigger does not become the event's start."
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20260902T140000Z" "DTEND:20260902T150000Z"
                           "SUMMARY:standup"
                           "BEGIN:VALARM" "TRIGGER:-PT10M"
                           "DTSTART:20250101T000000Z" "END:VALARM"
                           "END:VEVENT")
                 (aft--utc 2026 9 1 0 0) (aft--utc 2026 9 3 0 0))))
    (should (equal (aft--starts events) '("2026-09-02 14:00")))))

;;; Times

(ert-deftest aft-reads-a-zoned-start ()
  "A TZID is honoured, so 09:00 Chicago is 14:00 UTC in September."
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART;TZID=America/Chicago:20260902T090000"
                           "DTEND;TZID=America/Chicago:20260902T100000"
                           "SUMMARY:standup" "END:VEVENT")
                 (aft--utc 2026 9 1 0 0) (aft--utc 2026 9 3 0 0))))
    (should (equal (aft--starts events) '("2026-09-02 14:00")))))

(ert-deftest aft-falls-back-on-an-unknown-zone ()
  "An unrecognised TZID yields an event rather than failing the feed."
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART;TZID=Mars/Olympus:20260902T090000"
                           "DTEND;TZID=Mars/Olympus:20260902T100000"
                           "SUMMARY:standup" "END:VEVENT")
                 (aft--utc 2026 9 1 0 0) (aft--utc 2026 9 4 0 0))))
    (should (equal (aft--summaries events) '("standup")))))

(ert-deftest aft-marks-an-all-day-event ()
  "A VALUE=DATE event is all-day, and its end is the inclusive last day."
  (let* ((events (agenda-feeds-ics-events
                  (aft--ics "BEGIN:VEVENT" "UID:1"
                            "DTSTART;VALUE=DATE:20260902"
                            "DTEND;VALUE=DATE:20260904"
                            "SUMMARY:offsite" "END:VEVENT")
                  (aft--utc 2026 9 1 0 0) (aft--utc 2026 9 6 0 0)))
         (event (car events)))
    (should (= 1 (length events)))
    (should (plist-get event :all-day))
    ;; DTEND 09-04 is exclusive, so the last day shown is the 3rd.
    (should (equal (format-time-string "%Y-%m-%d" (plist-get event :end))
                   "2026-09-03"))))

(ert-deftest aft-uses-duration-when-dtend-is-absent ()
  "DURATION supplies the end when DTEND is missing."
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20260902T140000Z" "DURATION:PT90M"
                           "SUMMARY:review" "END:VEVENT")
                 (aft--utc 2026 9 1 0 0) (aft--utc 2026 9 3 0 0))))
    (should (equal (format-time-string "%H:%M" (plist-get (car events) :end) t)
                   "15:30"))))

;;; Recurrence

(ert-deftest aft-expands-a-daily-rule ()
  "A daily rule contributes one occurrence per day in the window."
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20260901T140000Z" "DTEND:20260901T143000Z"
                           "RRULE:FREQ=DAILY" "SUMMARY:standup" "END:VEVENT")
                 (aft--utc 2026 9 3 0 0) (aft--utc 2026 9 6 0 0))))
    (should (equal (aft--starts events)
                   '("2026-09-03 14:00" "2026-09-04 14:00"
                     "2026-09-05 14:00")))))

(ert-deftest aft-honours-interval ()
  "INTERVAL=2 skips every other day."
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20260901T140000Z" "DTEND:20260901T143000Z"
                           "RRULE:FREQ=DAILY;INTERVAL=2" "SUMMARY:standup"
                           "END:VEVENT")
                 (aft--utc 2026 9 1 0 0) (aft--utc 2026 9 7 0 0))))
    (should (equal (aft--starts events)
                   '("2026-09-01 14:00" "2026-09-03 14:00"
                     "2026-09-05 14:00")))))

(ert-deftest aft-counts-from-the-series-start-not-the-window ()
  "COUNT is exhausted by occurrences before the window, not just inside it."
  ;; Five daily occurrences from 09-01 run out on the 5th, so a window opening
  ;; on the 4th sees only two.  Expanding from the window would wrongly show
  ;; five.
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20260901T140000Z" "DTEND:20260901T143000Z"
                           "RRULE:FREQ=DAILY;COUNT=5" "SUMMARY:standup"
                           "END:VEVENT")
                 (aft--utc 2026 9 4 0 0) (aft--utc 2026 9 30 0 0))))
    (should (equal (aft--starts events)
                   '("2026-09-04 14:00" "2026-09-05 14:00")))))

(ert-deftest aft-stops-at-until ()
  "UNTIL ends the series even when the window runs on."
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20260901T140000Z" "DTEND:20260901T143000Z"
                           "RRULE:FREQ=DAILY;UNTIL=20260903T235959Z"
                           "SUMMARY:standup" "END:VEVENT")
                 (aft--utc 2026 9 1 0 0) (aft--utc 2026 9 30 0 0))))
    (should (equal (aft--starts events)
                   '("2026-09-01 14:00" "2026-09-02 14:00"
                     "2026-09-03 14:00")))))

(ert-deftest aft-expands-weekly-byday ()
  "A weekly rule with BYDAY hits each listed weekday."
  ;; 2026-09-01 is a Tuesday; Monday and Wednesday of that week are the 31st
  ;; of August and the 2nd of September.
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20260901T140000Z" "DTEND:20260901T143000Z"
                           "RRULE:FREQ=WEEKLY;BYDAY=MO,WE" "SUMMARY:sync"
                           "END:VEVENT")
                 (aft--utc 2026 9 1 0 0) (aft--utc 2026 9 10 0 0))))
    (should (equal (aft--starts events)
                   '("2026-09-02 14:00" "2026-09-07 14:00"
                     "2026-09-09 14:00")))))

(ert-deftest aft-does-not-emit-byday-before-dtstart ()
  "The first week's earlier weekdays are not occurrences."
  ;; DTSTART is Tuesday the 1st, so Monday the 31st must not appear even
  ;; though it is in that week and inside the window.
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20260901T140000Z" "DTEND:20260901T143000Z"
                           "RRULE:FREQ=WEEKLY;BYDAY=MO,WE" "SUMMARY:sync"
                           "END:VEVENT")
                 (aft--utc 2026 8 25 0 0) (aft--utc 2026 9 4 0 0))))
    (should (equal (aft--starts events) '("2026-09-02 14:00")))))

(ert-deftest aft-expands-monthly-and-skips-a-short-month ()
  "A monthly rule on the 31st skips months that have no 31st."
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20260131T140000Z" "DTEND:20260131T150000Z"
                           "RRULE:FREQ=MONTHLY" "SUMMARY:report" "END:VEVENT")
                 (aft--utc 2026 1 1 0 0) (aft--utc 2026 4 30 0 0))))
    ;; February has no 31st, so the series jumps to March.
    (should (equal (aft--starts events)
                   '("2026-01-31 14:00" "2026-03-31 14:00")))))

(ert-deftest aft-expands-yearly ()
  "A yearly rule repeats on its month and day."
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20240902T140000Z" "DTEND:20240902T150000Z"
                           "RRULE:FREQ=YEARLY" "SUMMARY:anniversary"
                           "END:VEVENT")
                 (aft--utc 2026 1 1 0 0) (aft--utc 2026 12 31 0 0))))
    (should (equal (aft--starts events) '("2026-09-02 14:00")))))

;;; Skipping ahead
;;
;; A series is not walked from its DTSTART when it does not have to be, which
;; is what keeps a real calendar interactive.  These cover the cases that
;; shortcut could get wrong.

(ert-deftest aft-skips-ahead-to-a-distant-window ()
  "A years-old daily series lands on the right days in a far-off window."
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20200101T140000Z" "DTEND:20200101T143000Z"
                           "RRULE:FREQ=DAILY" "SUMMARY:standup" "END:VEVENT")
                 (aft--utc 2026 9 2 0 0) (aft--utc 2026 9 5 0 0))))
    (should (equal (aft--starts events)
                   '("2026-09-02 14:00" "2026-09-03 14:00"
                     "2026-09-04 14:00")))))

(ert-deftest aft-skips-ahead-on-a-weekly-series ()
  "An old weekly BYDAY series keeps its weekdays after skipping ahead."
  ;; 2026-09-07 is a Monday and 2026-09-09 a Wednesday.
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20200107T140000Z" "DTEND:20200107T143000Z"
                           "RRULE:FREQ=WEEKLY;BYDAY=MO,WE" "SUMMARY:sync"
                           "END:VEVENT")
                 (aft--utc 2026 9 7 0 0) (aft--utc 2026 9 10 0 0))))
    (should (equal (aft--starts events)
                   '("2026-09-07 14:00" "2026-09-09 14:00")))))

(ert-deftest aft-skips-ahead-without-losing-a-straddling-week ()
  "A weekly period opening before the window still reaches into it."
  ;; The window opens mid-week on Wednesday the 9th; that week's Monday is
  ;; outside it, so the period must not be skipped past.
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20200108T140000Z" "DTEND:20200108T143000Z"
                           "RRULE:FREQ=WEEKLY;BYDAY=MO,WE" "SUMMARY:sync"
                           "END:VEVENT")
                 (aft--utc 2026 9 9 0 0) (aft--utc 2026 9 10 0 0))))
    (should (equal (aft--starts events) '("2026-09-09 14:00")))))

(ert-deftest aft-skips-ahead-on-a-monthly-series ()
  "An old monthly series lands on its day-of-month in a far-off window."
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20200115T140000Z" "DTEND:20200115T150000Z"
                           "RRULE:FREQ=MONTHLY" "SUMMARY:report" "END:VEVENT")
                 (aft--utc 2026 9 1 0 0) (aft--utc 2026 9 30 0 0))))
    (should (equal (aft--starts events) '("2026-09-15 14:00")))))

(ert-deftest aft-drops-a-series-that-ended-long-ago ()
  "An UNTIL in the past means no occurrences, without walking the series."
  (should (null (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20200101T140000Z" "DTEND:20200101T143000Z"
                           "RRULE:FREQ=DAILY;UNTIL=20200201T000000Z"
                           "SUMMARY:standup" "END:VEVENT")
                 (aft--utc 2026 9 1 0 0) (aft--utc 2026 9 5 0 0)))))

(ert-deftest aft-drops-a-series-whose-count-ran-out-long-ago ()
  "A COUNT exhausted before the window means no occurrences."
  (should (null (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20200101T140000Z" "DTEND:20200101T143000Z"
                           "RRULE:FREQ=DAILY;COUNT=10" "SUMMARY:standup"
                           "END:VEVENT")
                 (aft--utc 2026 9 1 0 0) (aft--utc 2026 9 5 0 0)))))

(ert-deftest aft-still-counts-an-old-series-that-reaches-the-window ()
  "A COUNT series is walked from the start, so its tail is still exact."
  ;; A weekly series of 500 from 2020-01-07 (a Tuesday) is still running in
  ;; 2026, and COUNT forbids skipping ahead.
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20200107T140000Z" "DTEND:20200107T143000Z"
                           "RRULE:FREQ=WEEKLY;COUNT=500" "SUMMARY:sync"
                           "END:VEVENT")
                 (aft--utc 2026 9 1 0 0) (aft--utc 2026 9 3 0 0))))
    (should (equal (aft--starts events) '("2026-09-01 14:00")))))

(ert-deftest aft-applies-exdate ()
  "An EXDATE removes that one occurrence."
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20260901T140000Z" "DTEND:20260901T143000Z"
                           "RRULE:FREQ=DAILY" "EXDATE:20260902T140000Z"
                           "SUMMARY:standup" "END:VEVENT")
                 (aft--utc 2026 9 1 0 0) (aft--utc 2026 9 4 0 0))))
    (should (equal (aft--starts events)
                   '("2026-09-01 14:00" "2026-09-03 14:00")))))

;;; Overrides and cancellation

(ert-deftest aft-a-moved-instance-appears-once ()
  "A RECURRENCE-ID event replaces its occurrence instead of adding to it."
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20260901T140000Z" "DTEND:20260901T143000Z"
                           "RRULE:FREQ=DAILY" "SUMMARY:standup" "END:VEVENT"
                           "BEGIN:VEVENT" "UID:1"
                           "RECURRENCE-ID:20260902T140000Z"
                           "DTSTART:20260902T160000Z" "DTEND:20260902T163000Z"
                           "SUMMARY:standup (moved)" "END:VEVENT")
                 (aft--utc 2026 9 2 0 0) (aft--utc 2026 9 3 0 0))))
    (should (equal (aft--starts events) '("2026-09-02 16:00")))
    (should (equal (aft--summaries events) '("standup (moved)")))))

(ert-deftest aft-drops-a-cancelled-event ()
  "STATUS:CANCELLED is not shown."
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20260902T140000Z" "DTEND:20260902T150000Z"
                           "STATUS:CANCELLED" "SUMMARY:gone" "END:VEVENT")
                 (aft--utc 2026 9 1 0 0) (aft--utc 2026 9 3 0 0))))
    (should (null events))))

;;; Windowing

(ert-deftest aft-keeps-an-event-straddling-the-window-start ()
  "An event already under way when the window opens is still shown."
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20260901T230000Z" "DTEND:20260902T010000Z"
                           "SUMMARY:long call" "END:VEVENT")
                 (aft--utc 2026 9 2 0 0) (aft--utc 2026 9 3 0 0))))
    (should (equal (aft--summaries events) '("long call")))))

(ert-deftest aft-drops-an-event-outside-the-window ()
  "An event wholly before the window does not appear."
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20260801T140000Z" "DTEND:20260801T150000Z"
                           "SUMMARY:last month" "END:VEVENT")
                 (aft--utc 2026 9 1 0 0) (aft--utc 2026 9 3 0 0))))
    (should (null events))))

(ert-deftest aft-sorts-by-start ()
  "Events come back in start order regardless of file order."
  (let ((events (agenda-feeds-ics-events
                 (aft--ics "BEGIN:VEVENT" "UID:2"
                           "DTSTART:20260902T160000Z" "DTEND:20260902T170000Z"
                           "SUMMARY:second" "END:VEVENT"
                           "BEGIN:VEVENT" "UID:1"
                           "DTSTART:20260902T090000Z" "DTEND:20260902T100000Z"
                           "SUMMARY:first" "END:VEVENT")
                 (aft--utc 2026 9 1 0 0) (aft--utc 2026 9 3 0 0))))
    (should (equal (aft--summaries events) '("first" "second")))))

(ert-deftest aft-reads-an-empty-calendar ()
  "A calendar with no events yields no events rather than an error."
  (should (null (agenda-feeds-ics-events
                 (aft--ics) (aft--utc 2026 9 1 0 0) (aft--utc 2026 9 3 0 0)))))

(provide 'agenda-feeds-ics-tests)
;;; agenda-feeds-ics-tests.el ends here
