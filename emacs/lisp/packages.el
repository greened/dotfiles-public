; -*- lexical-binding: t -*-
;;

;; (require 'package)

;; (setq package-archive-priorities
;;       '(("org" . 200)
;; 	("melpa-stable" . 150)
;; 	("melpa" . 100)¯
;;         ("marmalade" . 75)
;;         ("gnu" . 50)))

;; (setq package-user-dir (concat emacs-root "/site-lisp/packages"))

;; (package-initialize)

;; ; fetch the list of packages available
;; (unless package-archive-contents
;;   (package-refresh-contents))

;; (eval-when-compile
;;   (add-to-list 'load-path  (concat emacs-root "/site-lisp/use-package"))
;;   (require 'use-package))

;; Gnus inbox / split configuration.  Defined here (before any overlay
;; loads) so overlays can append entries and then rebuild the select
;; method via `my-gnus-rebuild-select-method'.
(defvar my-gnus-nnimap-inbox '("INBOX")
  "List of IMAP inboxes to fetch.  Overlays add entries.")

(defvar my-gnus-nnimap-split-fancy
  '(|
    (nil))
  "Fancy split rules for incoming mail.  Overlays add entries.")

(defun my-gnus-rebuild-select-method ()
  "(Re)build `gnus-select-method' from the my-gnus-* variables."
  (setq gnus-select-method
        `(nnimap "Local"
                 (nnimap-address "localhost")
                 (nnimap-authenticator login)
                 (nnimap-stream network)
                 (nnimap-inbox ,my-gnus-nnimap-inbox)
                 (nnimap-split-fancy ,my-gnus-nnimap-split-fancy)
                 (nnimap-split-methods nnimap-split-fancy))))

;; elpaca package management
(defvar elpaca-installer-version 0.7)
(defvar elpaca-directory (expand-file-name "elpaca/" user-emacs-directory))
(defvar elpaca-builds-directory (expand-file-name "builds/" elpaca-directory))
(defvar elpaca-repos-directory (expand-file-name "repos/" elpaca-directory))
(defvar elpaca-order '(elpaca :repo "https://github.com/progfolio/elpaca.git"
                              :ref nil :depth 1
                              :files (:defaults "elpaca-test.el" (:exclude "extensions"))
                              :build (:not elpaca--activate-package)))
(let* ((repo  (expand-file-name "elpaca/" elpaca-repos-directory))
       (build (expand-file-name "elpaca/" elpaca-builds-directory))
       (order (cdr elpaca-order))
       (default-directory repo))
  (add-to-list 'load-path (if (file-exists-p build) build repo))
  (unless (file-exists-p repo)
    (make-directory repo t)
    (when (< emacs-major-version 28) (require 'subr-x))
    (condition-case-unless-debug err
        (if-let ((buffer (pop-to-buffer-same-window "*elpaca-bootstrap*"))
                 ((zerop (apply #'call-process `("git" nil ,buffer t "clone"
                                                 ,@(when-let ((depth (plist-get order :depth)))
                                                     (list (format "--depth=%d" depth) "--no-single-branch"))
                                                 ,(plist-get order :repo) ,repo))))
                 ((zerop (call-process "git" nil buffer t "checkout"
                                       (or (plist-get order :ref) "--"))))
                 (emacs (concat invocation-directory invocation-name))
                 ((zerop (call-process emacs nil buffer nil "-Q" "-L" "." "--batch"
                                       "--eval" "(byte-recompile-directory \".\" 0 'force)")))
                 ((require 'elpaca))
                 ((elpaca-generate-autoloads "elpaca" repo)))
            (progn (message "%s" (buffer-string)) (kill-buffer buffer))
          (error "%s" (with-current-buffer buffer (buffer-string))))
      ((error) (warn "%s" err) (delete-directory repo 'recursive))))
  (unless (require 'elpaca-autoloads nil t)
    (require 'elpaca)
    (elpaca-generate-autoloads "elpaca" repo)
    (load "./elpaca-autoloads")))
(add-hook 'after-init-hook #'elpaca-process-queues)
(elpaca `(,@elpaca-order))
(setq package-enable-at-startup nil)

;; Install a package via the elpaca macro
;; See the "recipes" section of the manual for more details.

;; (elpaca example-package)

;; Remove builtin org - we use a downloaded package
;; (setq load-path (remove-if (lambda (x) (string-match-p "org$" x)) load-path))
;; (setq load-path (remove-if (lambda (x) (string-match-p "org-" x)) load-path))

(defvar local-repos-directory "~/src" "Directory for local repositories")

;; Get packages from local repositories first.
(defun elpaca-recipe-try-local (recipe)
  "If RECIPE's :try-local keyword is non-nil, return :repo relative to `local-repos-directory'"
  (when-let* (((plist-get recipe :try-local))
              (repo (plist-get recipe :repo))
              (local (expand-file-name (elpaca-git--repo-name repo) local-repos-directory))
              ((file-directory-p local)))
    (list :repo local)))

(setq elpaca-recipe-functions '(elpaca-recipe-try-local))

;; Install use-package support
(elpaca elpaca-use-package
  ;; Enable use-package :ensure support for Elpaca.
  (elpaca-use-package-mode)
  (setq elpaca-use-package-always-ensure t))

;; straight package management
;; (defvar bootstrap-version)
;; (let ((bootstrap-file
;;        (expand-file-name "straight/repos/straight.el/bootstrap.el" user-emacs-directory))
;;       (bootstrap-version 5))
;;   (unless (file-exists-p bootstrap-file)
;;     (with-current-buffer
;;         (url-retrieve-synchronously
;;          "https://raw.githubusercontent.com/raxod502/straight.el/develop/install.el"
;;          'silent 'inhibit-cookies)
;;       (goto-char (point-max))
;;       (eval-print-last-sexp)))
;;   (load bootstrap-file nil 'nomessage))

;; (straight-use-package 'use-package)

;; Just for listing packages.  No package-initialize
(require 'package)
(setq package-archives '(("melpa" . "http://melpa.org/packages/")
			 ("melpa-stable" . "http://stable.melpa.org/packages/")
                         ("gnu" . "http://elpa.gnu.org/packages/")
                         ;;("marmalade" . "http://marmalade-repo.org/packages/")
			 ("org" . "http://orgmode.org/elpa/")))

(setq warning-minimum-level :error)

;; Remove builtin org - we use a downloaded package
;;(setq load-path (remove-if (lambda (x) (string-match-p "org$" x)) load-path))
;;(setq load-path (remove-if (lambda (x) (string-match-p "org-" x)) load-path))

;; Update packages automatically.
(use-package auto-package-update
  :ensure t
  :config
  (setq auto-package-update-delete-old-versions t)
  (setq auto-package-update-hide-results t)
  (auto-package-update-maybe))

;; Upgrade builtin packages.
(setq package-install-upgrade-built-in t)

(use-package bind-key
  :ensure t
  :config
  (when (memq window-system '(mac ns x))
    (setq ns-control-modifier 'control
          ns-option-modifier 'super
          ns-command-modifier 'meta
          ns-right-option-modifier 'hyper)))

(use-package which-key
  :ensure t
  :config
  (which-key-mode +1))

(use-package org
  :ensure t
  :mode (("\\.org$" . org-mode))
  :config
  (require 'org-tempo)
;  (require 'org-protocol)
;  (require 'org)
;  (require 'ol-notmuch)
  (progn
    (global-set-key (kbd "C-c l") 'org-store-link)
    (global-set-key (kbd "C-c a") 'org-agenda)
    (global-set-key (kbd "C-c c") 'org-capture)
    (setq org-src-fontify-natively 1)
    (setq org-catch-invisible-edits `smart)
    (setq org-modules '(org-bbdb
			org-gnus
			org-info
			org-habit))
    (org-load-modules-maybe t)
    ;;(setq org-export-backends '(org latex beamer icalendar html md ascii))

    ;; Allow previewing TikZ sources.
    (add-to-list 'org-latex-packages-alist
                 '("" "tikz" t))
    ;;(eval-after-load "preview"
    ;;  '(add-to-list 'preview-default-preamble "\\PreviewEnvironment{tikzpicture}" t))
    (setq org-latex-create-formula-image-program 'imagemagick)

    ;; Allow easy creation of links.  Overlays add employer-specific
    ;; abbreviations (e.g. issue trackers).
    (setq org-link-abbrev-alist
	  '(("phab" . "https://reviews.llvm.org/%s")))

    ;; TODO tracking
    (setq org-todo-keywords
	  `((sequence "TODO(t)" "IN PROGRESS(p!)" "WAIT(w@/!)" "|" "DELEGATED(l!)" "DONE(d!)")  ;; Jiras
	    ;(sequence "TODO(t)" "WAIT(w@/!)" "|" "DONE(d!)" "CANCELED(c@)") ;; Ordinary tasks
	    ))
    (setq org-hierarchical-todo-statistics t)

    ;; integrate emacs diary entries into org agenda
    (setq org-agenda-include-diary t)

    ;; Log DONE state in TODOs
    (setq org-log-done 'note)

    (setq org-log-into-drawer t)

    ;; Put notes in the body with the prefix.
    (defun with-no-drawer (func &rest args)
      (interactive "P")
      (let ((org-log-into-drawer (not (car args))))
	(funcall func)))

    (advice-add 'org-add-note :around #'with-no-drawer)

    ;; Refile with outline paths
    (setq org-refile-use-outline-path t)
    (setq org-outline-path-complete-in-steps nil)
    (setq org-refile-targets '((nil :maxlevel . 9)
			       (org-agenda-files :maxlevel . 9)))
    ;; Tags
    (setq org-tag-alist '(
			  ;(:startgroup)
			  ("work" . ?w)
			  ;(:grouptags)
			  ("okr" . ?o)
			  ;(:endgroup)
			  ;(:startgroup)
			  ("home" . ?h)
			  ("overhead" . ?v)
			  ("planning" . ?p)
			  ("upstream" . ?u)
			  ("testing" . ?t)
			  ("classic" . ?l)
			  ("master" . ?m)
			  ("release" . ?r)
			  ("rome" . ?R)
			  ("compiler" . ?c)
			  ("dragon" . ?d)
			  ("schedregfma" . ?s)
			  ("time" . ?e)
			  ;(:endgroup)
			  ))

    ;; Babel
    (setq org-src-fontify-natively t)

    ;; Clocking
    (setq org-lock-persist 'history)
    (org-clock-persistence-insinuate)
    (setq org-clock-idle-time 10)

    (defun clocktable-by-tag/shift-cell (n)
      (let ((str ""))
	(dotimes (i n)
	  (setq str (concat str "| ")))
	str))

    (defun clocktable-by-tag/insert-tag (params)
      (let ((tag (plist-get params :tags)))
	(insert "|--\n")
	(insert (format "| %s | *Tag time* |\n" tag))
	(let ((tagtotal 0))
	  (mapcar
	   (lambda (file)
	     (let ((filetotal 0)
		   (clock-data (with-current-buffer (find-file-noselect file)
				 (org-clock-get-table-data (buffer-name) params))))
	       (when (> (nth 1 clock-data) 0)
		 (setq filetotal (+ filetotal (nth 1 clock-data)))
		 (insert (format "| | File *%s* | %.2f |\n"
				 (file-name-nondirectory file)
				 (/ (nth 1 clock-data) 60.0)))
		 (dolist (entry (nth 2 clock-data))
		   (when (member tag (nth 2 entry))
		     (setq tagtotal (+ tagtotal (nth 4 entry)))
		     (insert (format "| | . %s%s %s | %s %.2f |\n"
				     (org-clocktable-indent-string (nth 0 entry))
				     (nth 1 entry)
				     (nth 2 entry)
				     (clocktable-by-tag/shift-cell (nth 0 entry))
				     (/ (nth 4 entry) 60.0))))))))
	   (org-agenda-files))
	  (save-excursion
	    (re-search-backward "*Tag time*")
	    (org-table-next-field)
	    (org-table-blank-field)
	    (insert (format "*%.2f*" (/ tagtotal 60.0)))))
	(org-table-align)))

    (defun org-dblock-write:clocktable-by-tag (params)
      (let ((block (plist-get params :block)))
	(when block
	  (insert (format "| %s\n" (nth 2
					(org-clock-special-range
					 block nil t
					 (plist-get params :wstart)
					 (plist-get params :mstart)))))))
      (insert "| Tag | Headline | Time (h) |\n")
      (insert "|     |          | <r>  |\n")
      (let ((tags (plist-get params :tags)))
	(mapcar (lambda (tag)
		  (setq params (plist-put params :tags tag))
		  (clocktable-by-tag/insert-tag params))
		tags)))


    ;; Agenda files.  Overlays define their own note files and append them
    ;; to `org-agenda-files'.  Start empty so the base loads cleanly with no
    ;; overlay present.
    (setq org-agenda-files nil)

    (defun weekly-status/get-week-days-from-today (inc)
	"Return a list of days for the past week suitable for
passing to `org-agenda-get-day-entries."
      (let* ((today (org-today))
	     (day-list (list today)))
	(dotimes (n (1- 7) day-list)
	  (push (+ inc (car day-list)) day-list))))

    (defun weekly-status/files ()
      org-agenda-files)

    (defun weekly-status/deconstruct-heading (file-and-entry)
      "Return a list containing the starting point of the entry
and a list of components if found, nil otherwise."
      (save-excursion
	(let ((file (nth 0 file-and-entry))
	      (entry (nth 1 file-and-entry)))
	  (with-current-buffer (find-file file)
	    (goto-char (point-min))
	    (let ((entry-no-tags (if (string-match org-tag-group-re entry)
				     (replace-match "" nil nil entry)
				   entry)))
	      (if (search-forward entry-no-tags nil t)
	      (progn
		(beginning-of-line)
		(list file (point) (org-heading-components)))
	      nil))))))

    (defun weekly-status/filter-and-deconstruct-headings (entries)
      "Process a list of heading strings and return a list
composed of the starting point of the heading and a list of
components as returned by `org-heading-components`.  And entries
that are not found in the buffer are discarded.  These are
typically duplicates returned by `org-agenda-get-day-entries`
containing state changes and other metadata."
      (save-excursion
	(let ((new-entries (mapcar 'weekly-status/deconstruct-heading entries)))
	  (remove 'nil new-entries))))

    (defun weekly-status/filter-entries (file-and-entries)
      "Sanitize entries and remove duplicates."
      (setq new-entries nil)
      (dolist (file-and-entry file-and-entries new-entries)
	(let ((file (nth 0 file-and-entry))
	      (entry (nth 1 file-and-entry)))
	  (setq sanitized-entry entry)
	  (dolist (pattern (list "^[[:space:]]*[[:alnum:]]+:[[:space:]]*"  ;; Leading category
				 "^[[:space:]]*Sched[^:]+:[[:space:]]*"    ;; Scheduled notes
				 "^[[:space:]]*[0-9]+:[0-9]+-[0-9]+:[0-9]+[[:space:]+Clocked:[[:space:]]+([0-9]+:[0-9]+)[[:space:]]*"  ;; Clocked notes
				 "^[[:space:]]*\.*[[:space:]]+Closed:[[:space:]]+"  ;; Closed notes
				 "^[[:space:]]*[0-9]+:[0-9]+\.*[[:space:]]+"  ;; Unannotated))
				 ;;org-tag-group-re))  ;; Tags at end of the heading
				 ))
	    (setq sanitized-entry (if (string-match pattern sanitized-entry)
				      (replace-match "" nil nil sanitized-entry)
				    sanitized-entry)))
	  (if (not (memq sanitized-entry new-entries))
	      (push (list file sanitized-entry) new-entries)))))

    (defun weekly-status/add-closed-timestamp (file-and-entry days)
      "Add a timestamp if the item was closed during DAYS, nil otherwise"
      ;;(message (format "Add closed: %s" file-and-entry))
      (save-excursion
	(let* ((file (nth 0 file-and-entry))
	       (entry-point (nth 1 file-and-entry))
	       (entry-components (nth 2 file-and-entry))
	       (entry-notes (nth 3 file-and-entry)))
	  (list file entry-point entry-components entry-notes
		(with-current-buffer (find-file file)
		  (goto-char entry-point)
		  (end-of-line)
		  (let* ((entry-search-end-point (re-search-forward "^\\*+" nil t))
			 (entry-end-point (if entry-search-end-point
					      entry-search-end-point
					    (point-max)))
			 (closed-regexp (concat "CLOSED: " org-ts-regexp-inactive)))
		    (goto-char entry-point)
		    (end-of-line)
		    (setq closed-timestamp nil)
		    ;; Only add notes from the logbook.
		    (let ((closed-start-point (re-search-forward closed-regexp entry-end-point t)))
		      (if closed-start-point
			  (progn
			    (let* ((closed-date (match-string 1))
				   (closed-day (org-time-string-to-absolute closed-date)))
			      (if (memq closed-day days)
				  closed-date
				nil)))
			nil))))))))

    (defun weekly-status/make-add-closed-timestamp (days)
      (let ((tdays days))
	(lambda (entry)
	  (weekly-status/add-closed-timestamp entry tdays))))

    (defun weekly-status/add-closed-timestamps (days file-and-entries)
      "Process a list of entries and return a list of (entry
closed) where closed will be nil if the entry was not closed in
days"
      (save-excursion
	(mapcar (weekly-status/make-add-closed-timestamp days) file-and-entries)))

    (defun weekly-status/add-entry-notes (file-and-entry days)
      "Add notes for each entry"
      (save-excursion
	(let* ((file (nth 0 file-and-entry))
	       (entry-point (nth 1 file-and-entry))
	       (entry-components (nth 2 file-and-entry))
	       (entry-level (nth 0 entry-components))
	       (entry-reduced-level (nth 1 entry-components))
	       (entry-todo (nth 2 entry-components))
	       (entry-priority (nth 3 entry-components))
	       (entry-headline (nth 4 entry-components))
	       (entry-tags (nth 5 entry-components)))
	  (with-current-buffer (find-file file)
	    (goto-char entry-point)
	    (end-of-line)
	    (let* ((entry-search-end-point (re-search-forward "^\\*+" nil t))
		   (entry-end-point (if entry-search-end-point
					entry-search-end-point
				      (point-max)))
		   (note-regexp (concat "Note taken on " org-ts-regexp-inactive)))
	      (goto-char entry-point)
	      (end-of-line)
	      (setq notes nil)
	      ;; Only add notes from the logbook.
	      (let ((logbook-start-point (re-search-forward ":LOGBOOK:" entry-end-point t)))
		(when logbook-start-point
		  (let ((logbook-end-point (re-search-forward ":END:" entry-end-point)))
                    (message (format "Looking at logbook %s %s" logbook-start-point logbook-end-point))
		    (goto-char logbook-start-point)
                    (message "Finding first note")
		    (setq found-note-point (re-search-forward note-regexp
							      logbook-end-point t))
		    (while found-note-point
		      (forward-line 0)
		      (forward-line)
                      (message (format "[1] At point %s" (point)))
		      (let* ((note-date (match-string 1))
			     (note-start-point (point))
			     (note-day (org-time-string-to-absolute note-date)))
			(when (memq note-day days)
			  (while (looking-at "[[:space:]]+")
			    (forward-line)
                            (message (format "[2] At point %s" (point))))

			  (let* ((note-end-point (point))
				 (note-text (buffer-substring note-start-point note-end-point)))
			    (push (list note-date note-text) notes))))
                      (message "Finding next note")
		      (setq found-note-point (re-search-forward note-regexp
								logbook-end-point t))))))
	      (list file entry-point entry-components notes))))))

    (defun weekly-status/make-add-entry-notes (days)
      (let ((tdays days))
	(lambda (entry)
	  (weekly-status/add-entry-notes entry tdays))))

    (defun weekly-status/add-notes (days file-and-entries)
      "Process a list of entries and return a list of (entry
notes) where notes may be nil.  Added notes are for one of the
days in days."
      (save-excursion
	(mapcar (weekly-status/make-add-entry-notes days) file-and-entries)))

    (defun weekly-status/flatten-file-and-entries (files-and-entries)
      "Transform a list of ((file, (entries))) to a list of ((file, entry))"
      (setq flattened nil)
      (dolist (file-and-entries files-and-entries flattened)
	(let ((file (nth 0 file-and-entries))
	      (entries (nth 1 file-and-entries)))
	  (dolist (entry entries)
	    (push (list file entry) flattened)))))

    (defun weekly-status/construct-this-week-items (days &rest args)
      (setq this-week-plan-items nil)
      (let ((this-week-entries
	     (dolist (day days this-week-plan-items)
	       (let ((date (calendar-gregorian-from-absolute day)))
		 (dolist (file (weekly-status/files))
		   (org-check-agenda-file file)
		   (let ((day-entries (apply 'org-agenda-get-day-entries file date args)))
		     (when day-entries
		       (setq this-week-plan-items
			     (push (list file day-entries) this-week-plan-items)))))))))
	(weekly-status/add-closed-timestamps days
	 (weekly-status/add-notes days
				  (weekly-status/filter-and-deconstruct-headings
				   (weekly-status/filter-entries
				    (weekly-status/flatten-file-and-entries this-week-entries)))))))

    (defun weekly-status/get-this-week-items (timeframe &rest args)
      "Get the items scheduled for the past week."
      (apply `weekly-status/construct-this-week-items
	     (weekly-status/get-week-days-from-today
	      (if (eq timeframe 'lastweek)
		  -1
		1))
	     args))

    (defun weekly-status/insert-entry (file-and-entry-plus-notes &optional add-notes add-closed)
      ;;(message (format "Inserting: %s" file-and-entry-plus-notes))
      (let* ((file (nth 0 file-and-entry-plus-notes))
	     (entry-point (nth 1 file-and-entry-plus-notes))
	     (entry-components (nth 2 file-and-entry-plus-notes))
	     (entry-notes (nth 3 file-and-entry-plus-notes))
	     (entry-closed (nth 4 file-and-entry-plus-notes))
	     (entry-level (nth 0 entry-components))
	     (entry-reduced-level (nth 1 entry-components))
	     (entry-todo (nth 2 entry-components))
	     (entry-priority (nth 3 entry-components))
	     (entry-headline (nth 4 entry-components))
	     (entry-tags (nth 5 entry-components)))
	(insert (format "| **%s** %s | **%s**\n" entry-todo entry-headline entry-tags))
	(when add-notes
	  (dolist (entry-note entry-notes)
	    (let ((entry-note-date (nth 0 entry-note))
		  (entry-note-text (nth 1 entry-note))
                  (notes-leader "| > :"))
	      (insert
               (format
                "| %s\n"
		(replace-regexp-in-string
                 "^\\(.*\\)" "\\1"
		 (replace-regexp-in-string "\n+" "" entry-note-text)))))))
	(when (and add-closed entry-closed)
	  (insert (format "| > **CLOSED**: [%s]\n" entry-closed)))))

    (defun weekly-status/insert-list (heading this-week-list &optional add-notes add-closed separator)
      (insert "|----\n")
      (insert "| ## " heading " |\n")
      (let ((processed nil))
	(dolist (entry (reverse this-week-list))
	  (unless (member entry processed)
	    (weekly-status/insert-entry entry add-notes add-closed)
	    (when separator
	      (insert separator "\n"))
	    (push entry processed))))
      (insert "|----\n"))

    (defun weekly-status/filter-for-done (entries)
      "Remove entries that were not closed"
      (setq new-entries nil)
      (dolist (entry entries new-entries)
	;;(message (format "Filtering: %s" entry))
	(let* ((entry-closed (nth 4 entry)))
	  (when entry-closed
	    (push entry new-entries)))))

    (defun org-dblock-write:weekly-status (params)
      (insert "|----\n")
      (let ((org-agenda-show-log-scoped nil))
	(insert (format "| # Weekly status report for [%s] |\n" (format-time-string "%Y/%m/%d")))
	(insert "|----\n")
	(weekly-status/insert-list "This week plans" (weekly-status/get-this-week-items 'lastweek :scheduled :timestamp))
	(weekly-status/insert-list "Accomplishments" (weekly-status/filter-for-done (weekly-status/get-this-week-items 'lastweek :closed)) nil t)
	(let ((org-agenda-show-log-scoped nil))
	  (weekly-status/insert-list "Work done"(weekly-status/get-this-week-items 'lastweek :closed) t nil "| |"))
	(weekly-status/insert-list "Next week plans" (weekly-status/get-this-week-items 'thisweek :scheduled :timestamp))))

    ;; Agenda commands
    (setq org-agenda-custom-commands nil)
    (defun air-org-skip-subtree-if-priority (priority)
      "Skip an agenda subtree if it has a priority of PRIORITY.

PRIORITY may be one of the characters ?A, ?B, or ?C."
      (let ((subtree-end (save-excursion (org-end-of-subtree t)))
            (pri-value (* 1000 (- org-lowest-priority priority)))
            (pri-current (org-get-priority (thing-at-point 'line t))))
	(if (= pri-value pri-current)
            subtree-end
	  nil)))

    (defun air-org-skip-subtree-if-habit ()
      "Skip an agenda entry if it has a STYLE property equal to \"habit\"."
      (let ((subtree-end (save-excursion (org-end-of-subtree t))))
	(if (string= (org-entry-get nil "STYLE") "habit")
            subtree-end
	  nil)))

    (add-to-list 'org-agenda-custom-commands
		 '("g" "Global view"
		   ((tags "PRIORITY=\"A\""
			  ((org-agenda-skip-function '(org-agenda-skip-entry-if 'todo 'done))
			   (org-agenda-overriding-header "High-priority unfinished tasks:")))
		    (agenda "" ((org-agenda-ndays 1)))
		    (alltodo ""
			     ((org-agenda-skip-function
			       '(or (air-org-skip-subtree-if-habit)
				    (org-agenda-skip-entry-if 'scheduled)))
			      (org-agenda-overriding-header "Unscheduled tasks:")))
		    (alltodo ""
			     ((org-agenda-skip-function
			       '(or (air-org-skip-subtree-if-habit)
				    (air-org-skip-subtree-if-priority ?A)
				    (org-agenda-skip-if nil '(scheduled deadline))))
			      (org-agenda-overriding-header "ALL normal priority tasks:")))))
		 t)

    ;; Capture templates are supplied by overlays, each of which knows its
    ;; own note files.  Start empty so the base loads cleanly with no overlay
    ;; present.
    (setq org-capture-templates nil)))

(use-package exec-path-from-shell
  :ensure t
  :config
  ;; (add-to-list 'exec-path-from-shell-variables "MODULESHOME")
  ;; (add-to-list 'exec-path-from-shell-variables "MODULEPATH")
  ;; (add-to-list 'exec-path-from-shell-variables "LOADEDMODULES")

  (when (memq window-system '(mac ns x))
    (exec-path-from-shell-initialize)))

(use-package tramp
  :ensure (:repo "https://git.savannah.gnu.org/git/tramp.git"
                 :pre-build
                  (("autoconf")
                   ("./configure")
                   ("make")))
  ;; :straight (tramp :type git
  ;;                  :repo "https://git.savannah.gnu.org/git/tramp.git"
  ;;                  :host nil
  ;;                  :pre-build
  ;;                  (("autoconf")
  ;;                   ("./configure")
  ;;                   ("make")))
  :demand t
;  :init
;  (tramp #'autoload-register-crypt-file-name-handler "tramp-crypt")
  :config
  (setq tramp-verbose 1)
  (setq tramp-default-method "ssh")
  (setq tramp-shell-prompt-pattern "\\(?:^\\|\r\\)[^]#$%>\n]*#?[]#$%>].* *\\(^[\\[[0-9;]*[a-zA-Z] *\\)*")

  (setq vc-ignore-dir-regexp
        (format "\\(%s\\)\\|\\(%s\\)"
	        vc-ignore-dir-regexp
	        tramp-file-name-regexp))

  ;; Honor remote PATH.  Overlays add site-specific bin directories.
  (add-to-list 'tramp-remote-path 'tramp-own-remote-path)

  ;; Cache remote file attributes to avoid repeated stat calls.
  (setq remote-file-name-inhibit-cache 20)

  ;; Reuse SSH connections via ControlMaster/ControlPersist so each
  ;; TRAMP operation does not open a fresh SSH handshake.
  ;;
  ;; Seems to hang TRAMP?
  (customize-set-variable 'tramp-use-ssh-controlmaster-options t)
  (setq tramp-ssh-controlmaster-options
        (concat "-o ControlMaster=auto"
                " -o ControlPath=" (expand-file-name "~/.ssh/tramp-%%r@%%h:%%p")
                " -o ControlPersist=yes"))
  ;;(customize-set-variable 'tramp-use-ssh-controlmaster-options nil)

  ;;(setq tramp-verbose 6)

  ;; If TRAMP asks for passwords, try running these.
  ;;(setq session-file-alist ())
  ;;(setq file-name-history ())

  (if (eq window-system 'w32)
                                        ;(setq tramp-default-method "ssh")
    (setq tramp-default-method "scp")
                                        ;(setq tramp-default-method "scpx")
  (setq tramp-default-method "ssh"))

  ;;(setq tramp-default-method "ssh")
  ;;(tramp-change-syntax 'simplified)
  ;setq(setq tramp-verbose 10)
  ;(setq tramp-debug-buffer t)
  ;; (connection-local-set-profile-variables 'remote-bash
  ;;                                         '((shell-file-name . "/bin/bash")
  ;;                                           (shell-command-switch . "-c")))

  ;; ;; Always use bash as the remote shell.
  ;; (connection-local-set-profiles
  ;;  '(:application tramp nil)
  ;;  'remote-bash)
  )

;;(autoload #'tramp-register-crypt-file-name-handler "tramp-crypt")
;;(require 'tramp)

(setq tramp-default-method "ssh")
(setq tramp-shell-prompt-pattern "\\(?:^\\|\r\\)[^]#$%>\n]*#?[]#$%>].* *\\(^[\\[[0-9;]*[a-zA-Z] *\\)*")

(setq vc-ignore-dir-regexp
      (format "\\(%s\\)\\|\\(%s\\)"
	      vc-ignore-dir-regexp
	      tramp-file-name-regexp))

;; Honor remote PATH.
;;(add-to-list 'tramp-remote-path 'tramp-own-remote-path)

;; ControlMaster is configured in the use-package tramp block above.

(if (eq window-system 'w32)
                                        ;(setq tramp-default-method "ssh")
    (setq tramp-default-method "scp")
                                        ;(setq tramp-default-method "scpx")
  (setq tramp-default-method "ssh"))

(require 'compile)
;; (require 'diminish)  ;; if you use :diminish
(require 'server)

(require 'ansi-color)
(defun my/ansi-colorize-buffer ()
  (let ((buffer-read-only nil))
    (ansi-color-apply-on-region (point-min) (point-max))))
(add-hook 'compilation-filter-hook 'my/ansi-colorize-buffer)
(setq compilation-search-path '(nil "./build/x86_64/devrel/llvm-project" "./build/x86_64/devdbg/llvm-project"))

(use-package whitespace
  :ensure nil
  :preface
  (defun no-trailing-whitespace ()
    "Turn off display of trailing whitespace in this buffer."
    (setq show-trailing-whitespace nil)
    (whitespace-mode))
  :init
  ;; But don't show trailing whitespace in SQLi, inf-ruby etc.
  (dolist (hook '(artist-mode-hook
                  picture-mode-hook
                  special-mode-hook
                  Info-mode-hook
                  eww-mode-hook
                  term-mode-hook
                  vterm-mode-hook
                  comint-mode-hook
                  compilation-mode-hook
                  twittering-mode-hook
                  minibuffer-setup-hook
                  fundamental-mode))
    (add-hook hook (lambda() (setq show-trailing-whitespace nil))))
    ;;(add-hook hook #'no-trailing-whitespace)
  :diminish whitespace-mode)

;;(require 'whitespace)

;;(require 'org-import-icalendar)

;; reduce the frequency of garbage collection by making it happen on
;; each 50MB of allocated data (the default is on every 0.76MB)
;;(setq gc-cons-threshold 50000000)

;; nice scrolling
(setq scroll-margin 0
      scroll-conservatively 100000
      scroll-preserve-screen-position 1)

;; mode line settings
(line-number-mode t)
(column-number-mode t)
(size-indication-mode t)

;; enable y/n answers
(fset 'yes-or-no-p 'y-or-n-p)

;; more useful frame title, that show either a file or a
;; buffer name (if the buffer isn't visiting a file)
(setq frame-title-format
      '((:eval (if (buffer-file-name)
                   (abbreviate-file-name (buffer-file-name))
                 "%b"))))

;; Emacs modes typically provide a standard means to change the
;; indentation width -- eg. c-basic-offset: use that to adjust your
;; personal indentation width, while maintaining the style (and
;; meaning) of any files you load.
(setq-default indent-tabs-mode nil)   ;; don't use tabs to indent
(setq-default tab-width 8)            ;; but maintain correct appearance

;; Newline at end of file
(setq require-final-newline t)

;; Wrap lines at 80 characters
(setq-default fill-column 80)

;; hippie expand is dabbrev expand on steroids
(setq hippie-expand-try-functions-list '(try-expand-dabbrev
                                         try-expand-dabbrev-all-buffers
                                         try-expand-dabbrev-from-kill
                                         try-complete-file-name-partially
                                         try-complete-file-name
                                         try-expand-all-abbrevs
                                         try-expand-list
                                         try-expand-line
                                         try-complete-lisp-symbol-partially
                                         try-complete-lisp-symbol))

;; use hippie-expand instead of dabbrev
(global-set-key (kbd "M-/") #'hippie-expand)
(global-set-key (kbd "s-/") #'hippie-expand)

;; replace buffer-menu with ibuffer
(global-set-key (kbd "C-x C-b") #'ibuffer)

;; align code in a pretty way
(global-set-key (kbd "C-x \\") #'align-regexp)

;; smart tab behavior - indent or complete
(setq tab-always-indent 'complete)

;; Built-in packages

;; (use-package emms-setup
;;   :init
;;   (add-hook 'emms-player-started-hook 'emms-show)
;;   (setq emms-show-format "Playing: %s")
;;   :config
;;   (emms-all)
;;   (emms-default-players))

(use-package emms
  :init
  (add-hook 'emms-player-started-hook 'emms-show)
  (setq emms-show-format "Playing: %s")
  :config
  (require 'emms-setup)
  (require 'emms-player-mpd)
  (emms-all)
  (setq emms-player-list '(emms-player-mpd))
  (add-to-list 'emms-info-functions 'emms-info-mpd)
  (add-to-list 'emms-player-list 'emms-player-mpd)

    ;; Socket is not supported
  (setq emms-player-mpd-server-name "localhost")
  (setq emms-player-mpd-server-port "6600")
  ;; Overlays set `emms-player-mpd-music-directory'.
  (add-hook 'emms-playlist-cleared-hook 'emms-player-mpd-clear)
  (emms-player-mpd-connect))

(use-package eudc
  :ensure nil
  :config
  (require 'eudcb-bbdb)
  ;;(use-package eudcb-bbdb
  ;;  :straight t)
  (setq message-expand-name-databases '(eudc))

  ;; Do email address expansion in email composition buffers.
  (eval-after-load
      "message"
    '(define-key message-mode-map [(control ?c) (tab)] 'eudc-expand-inline))
  (eval-after-load
      "sendmail"
    '(define-key mail-mode-map [(control ?c) (tab)] 'eudc-expand-inline))

  (setq eudc-default-return-attributes nil
        eudc-strict-return-matches nil)

  (setq ldap-ldapsearch-args (quote ("-tt" "-LLL" "-x")))
  (setq eudc-inline-query-format '((name)
                                   (firstname)
                                   (firstname name)
                                   (email)
                                   ))

  (setq ldap-host-parameters-alist
        (quote (("ldap.hp.com:389" base "o=hp.com"))))

  ;; Use BBDB first, then LDAP if at work.

  (eudc-set-server "localhost" 'bbdb t);;main server
  (setq eudc-inline-expansion-servers 'hotlist);;search in hotlist order
  (add-to-list 'eudc-server-hotlist '("localhost" . bbdb) t)
  (eudc-protocol-set 'eudc-inline-query-format
                     '((firstname)
                       (lastname)
                       (firstname lastname)
                       (net))
                     'bbdb)
  (eudc-protocol-set 'eudc-inline-expansion-format
                     '("%s %s <%s>" firstname lastname net)
                     'bbdb)

  (add-to-list 'eudc-server-hotlist '("localhost" . bbdb) t)

  ;; Add work LDAP
  (add-to-list 'eudc-server-hotlist '("ldap.hp.com:389" . ldap) t)
  (setq ldap-host-parameters-alist '(("ldap.hp.com:389" base "o=hp.com" auth simple 
                                      scope subtree))
        eudc-query-form-attributes '(uid name firstname email))
  (eudc-protocol-set 'eudc-inline-query-format
                     '(;(cn)
					;(cn cn)
					;(cn cn cn)
					;(sn)
					;(givenname)
					;(surname)
					;(givenname surname)
					;(fullname)
                       (firstname)
                       (name)
                       (email)
                       (firstname name)
					;(surname)
                       )
                     'ldap)
  (eudc-protocol-set 'eudc-inline-expansion-format
                     '("%s <%s>" cn mail)
                     'ldap)

  (defun enz-eudc-expand-inline()
    (interactive)
    (move-end-of-line 1)
    (insert "*")
    (unless (condition-case nil
                (eudc-expand-inline)
              (error nil))
      (backward-delete-char-untabify 1))
    ))

(use-package bbdb
  :ensure nil
  :config
  ;; Integrate sendmail and bbdb
  (add-hook 'mail-setup-hook 'bbdb-insinuate-sendmail)
  (add-hook 'message-setup-hook 'bbdb-mail-aliases)
  (bbdb-mua-auto-update-init)
  (setq bbdb-add-name 1)
  (bbdb-initialize 'gnus 'message))
;;(use-package 'bbdb-hooks)

(use-package gnus
  :ensure nil
  :config
  ;; Integrate gnus and bbdb
  (add-hook 'gnus-startup-hook 'bbdb-insinuate-gnus)

  ;; Turn on debugging
  (setq imap-log t)
  (setq nnimap-log-command t)
  (setq nnmail-split-tracing t)
  (setq nnimap-record-commands t)
  (setq nnmail-debug-splitting t)

  ;; Use the gnus registry
  (require 'gnus-registry)
  (gnus-registry-initialize)

  ;; Use gnus to read mail.
  (setq mail-user-agent 'gnus-user-agent)
  (setq read-mail-command 'gnus)

  ;; Setting the imap-ssl-program like this isn't strictly necessary, but
  ;; I do it anyway since I'm paranoid. (I think it will default to
  ;; `-ssl2' instead of `-tls1' if you don't do this.)
  (setq imap-ssl-program "openssl s_client -tls1 -connect %s:%p")

  ;; Keep read mail unless explicitly deleted
  (setq nnmail-expiry-wait 2)

  ;; Automatically log in.
  (setq nntp-authinfo-file "~/.authinfo")

  ;; Since I use gnus primarily for mail and not for reading News, I
  ;; make my IMAP setting the default method for gnus.  The set of
  ;; inboxes and the split rules are employer/identity specific, so
  ;; overlays populate `my-gnus-nnimap-inbox' and
  ;; `my-gnus-nnimap-split-fancy' (defined near the top of this file) and
  ;; then call `my-gnus-rebuild-select-method'.
  (my-gnus-rebuild-select-method)

  ;; Fetch only part of the article if we can.  I saw this in someone
  ;; else's .gnus
  (setq gnus-read-active-file 'some)

  ;; Tree view for groups.  I like the organisational feel this has.
  (add-hook 'gnus-group-mode-hook 'gnus-topic-mode)

  ;; Threads!  I hate reading un-threaded email -- especially mailing
  ;; lists.  This helps a ton!
  (setq gnus-summary-thread-gathering-function
        'gnus-gather-threads-by-subject)

  ;; Also, I prefer to see only the top level message.  If a message has
  ;; several replies or is part of a thread, only show the first
  ;; message.  'gnus-thread-ignore-subject' will ignore the subject and
  ;; look at 'In-Reply-To:' and 'References:' headers.
  (setq gnus-thread-hide-subtree t)
  (setq gnus-thread-ignore-subject t)

  ;; Let Gnus change the "From:" line by looking at current group we
  ;; are in.  Overlays supply the generic name entry and the per-account
  ;; (address/gcc) entries; start empty so the base is identity-free.
  (setq gnus-posting-styles nil)
  ;; Run the function gnus-user-format-function-G to get the string to
  ;; put in the group-line instead of the string "%uG".
  (setq gnus-group-line-format "%M%S%5y/%-5t: %uG %D\n")
  (defun gnus-user-format-function-G (arg)
    (concat (car (cdr gnus-tmp-method)) ":"
            (or (gnus-group-find-parameter gnus-tmp-group 'display-name)
                (let ((prefix (assq 'remove-prefix (cddr gnus-tmp-method))))
                  (if (and prefix
                           (string-match (concat "^\\("
                                                 (regexp-quote (cadr prefix))
                                                 "\\)")
                                         gnus-tmp-qualified-group))
                      (substring gnus-tmp-qualified-group (match-end 1))
                    gnus-tmp-qualified-group)))))

  ;;(setq gnus-message-archive-group "nnimap:INBOX.Sent")
  ;;(setq gnus-message-archive-method
  ;;      '(nnfolder "archive"
  ;;		 (nnfolder-inhibit-expiry t)
  ;;		 (nnfolder-active-file "~/Mail/sent-mail/active")
  ;;		 (nnfolder-directory "~/Mail/sent-mail/")))

  ;;(setq gnus-message-archive-group
  ;;      '((if (message-news-p)
  ;;	    "sent-news"
  ;;	  "sent-mail")))

  ;; Handle MIME types

  ;; Inline images?
  (setq mm-attachment-override-types '("image/.*"))
  (setq mm-enable-external "ask")

  ;;(mailcap-add-mailcap-entry "application" "x-mspowerpoint" `((viewer . "/opt/cpkg/v6/openoffice/2.0.2/program/soffice %s")
  ;;							    (type . "application/x-mspowerpoint")
  ;;							    ("copiousoutput" . t)))
  ;; BBDB Integration
  ;;(autoload 'bbdb/send-hook "moy-bbdb"
  ;;  "Function to be added to `message-send-hook' to notice records when sending messages" t)
  ;;(add-hook 'message-send-hook 'bbdb/send-hook) ; If you use Gnus
  ;;(add-hook 'mail-send-hook 'bbdb/send-hook) ; For other mailers
  ;; (VM, Rmail)
  ;;(bbdb-insinuate-gnus)
  ;;(setq bbdb-always-add-addresses t)
  ;;(setq bbdb/news-auto-create-p t)
  ;;(setq bbdb-dwim-net-address-allow-redundancy t)
  ;;(setq bbdb-complete-name-allow-cycling t)


   ;; configure nnfolder to save sent messages and drafts
   ;; in this case it uses folders named ``sent.YEAR'' which
   ;; are created and rotated automatically
  ;;   (setq nnfolder-active-file (expand-file-name "~/News/archive/active"))
  ;;    (setq nnnfolder-directory (expand-file-name "~/News/archive/"))
  ;;   (setq gnus-message-archive-method
  ;;       '(nnfolder "archive"
  ;;           (nnfolder-inhibit-expiry t)))
  ;;   (setq gnus-message-archive-group (concat "sent." (format-time-string "%Y")))
  ;;   (setq nndraft-directory (expand-file-name "~/News/drafts"))

  (defun gnus-browse-imaps-server (server)
    "Browse a mail server in Gnus via IMAP-SSL."
    (interactive "sServer name: ")
    (gnus-group-browse-foreign-server
     (list 'nnimap server
           (list 'nnimap-address server)
           '(nnimap-stream ssl)
           '(nnimap-list-pattern ("INBOX" "mail/*" "Mail/*" "INBOX.*"))
           '(nnimap-expunge-on-close ask))))


  ;; Print the article number, author, date and subject.
  (setq gnus-summary-line-format "%U%R%z%I%(%[%4L: %-24,24&user-date; | %-23,23f%]%) %s\n")

  ;; Auto-wash articles
  (setq gnus-treat-body-boundary (quote head))
  (setq gnus-treat-buttonize t)
  (setq gnus-treat-buttonize-head (quote head))
  (setq gnus-treat-display-x-face (quote head))
  (setq gnus-treat-emphasize t)
  (setq gnus-treat-fill-long-lines (quote (typep "text/plain")))
  (setq gnus-treat-fold-headers (quote head))
  (setq gnus-treat-from-gravatar (quote head))
  (setq gnus-treat-from-picon (quote head))
  (setq gnus-treat-hide-boring-headers (quote head))
  (setq gnus-treat-mail-gravatar (quote head))
  (setq gnus-treat-mail-picon (quote head))
  (setq gnus-treat-newsgroups-picon (quote head))
  (setq gnus-treat-unsplit-urls t)

  ;; Sort threads
  ;; (setq gnus-thread-sort-functions
  ;;       '(gnus-thread-sort-by-number gnus-thread-sort-by-most-recent-date))

  ;; (setq gnus-subthread-sort-functions
  ;;       '(gnus-thread-sort-by-number gnus-thread-sort-by-date))

  (setq gnus-sort-gathered-threads-function 'gnus-thread-sort-by-date)

  ;; Scoring
  (setq gnus-save-score t)
  (setq gnus-use-adaptive-scoring '(word line))
  (setq gnus-adaptive-word-length-limit 5)
  (setq gnus-adaptive-word-no-group-words t)

  ;; Be Windows friendly and don't create files with characters Windows
  ;; doesn't like.
  ;; (setq nnheader-file-name-translation-alist '((?: . ?_) (?[ . ?_) (?] . ?_)) )

  (setq gnus-default-adaptive-score-alist
        '((gnus-unread-mark)
          (gnus-ticked-mark (from 4))
          (gnus-dormant-mark (from 5))
          (gnus-del-mark (from -4) (subject -1))
          (gnus-read-mark (from 4) (subject 2))
          (gnus-expirable-mark (from -1) (subject -1))
          (gnus-killed-mark (from -1) (subject -3))
          (gnus-kill-file-mark)
          (gnus-ancient-mark)
          (gnus-low-score-mark)
          (gnus-catchup-mark (from -1) (subject -1))))

  ;; Prioritize mail from people we know about.
  (setq bbdb/gnus-score-default 2000)
  (setq gnus-score-find-score-files-function '(gnus-score-find-bnews.span class=compcode>bbdb/gnus-score)) 

  ;; Score up replies to our messages.
  (add-hook 'message­sent­hook 'gnus­score­followup­article)

  ;; Don't render HTML by default.
  ;;(setq mm-automatic-display (remove "text/html" mm-automatic-display))

  ;; But allow rendering with W H.
  ;; (setq mm-text-html-renderer nil)
  ;; (defun wicked/gnus-article-show-html ()
  ;;  "Show the current message as HTML mail."
  ;;  (interactive)
  ;;  (let ((mm-automatic-display (cons "text/html" mm-automatic-display)))
  ;;    (gnus-summary-show-article)))
  ;; (define-key gnus-article-mode-map "WH" 'wicked/gnus-article-show-html)

  ;; Splitting
  ;; (setq nnimap­split­inbox "INBOX")
  ;; (setq nnimap­split­predicate "UNDELETED")
  ;;  (setq nnmail­split­fancy
  ;;       '(|
  ;;         (: gnus­registry­split­fancy­with­parent)
  ;;          ;; splitting rules go here
  ;;         (from mail "INBOX.errors")   ;;
  ;;         (any "you@work.example.com" "INBOX.work")
  ;;         (any "you@personal.example.com" "INBOX.personal") ;;
  ;;         ("subject" "emacs" "INBOX.emacs")
  ;;         "INBOX"    ;; or "mail.misc" for nnml/POP3
  ;;        ))
  ;;  (setq nnimap­split­rule 'nnmail­split­fancy)
  ;;  (setq nnmail­split­methods 'nnimap­split­fancy)

  ;; Update mail every two minutes.
  (setq gnus-demon-timestep 60)
  (gnus-demon-add-handler 'gnus-group-get-new-news 2 t)
  (gnus-demon-init)

  ;;(use-package 'gnus-desktop-notify)
  ;;(gnus-desktop-notify-mode)
  ;;(gnus-demon-add-scanmail)
  ;;(setq gnus-desktop-notify-groups 'gnus-desktop-notify-explicit)

  ;; View all the MIME parts in current article
  (setq gnus-mime-view-all-parts t)

  )

(use-package eterm-256color
  :ensure t
  :config
  (add-hook 'term-mode-hook #'eterm-256color-mode))

(use-package vterm
  :ensure t
  :config
  (setq vterm-term-environment-variable "xterm-256color")
  (setq vterm-buffer-name-string "vterm %s")
  (add-hook 'vterm-mode-hook
            (lambda ()
              (set (make-local-variable 'buffer-face-mode-face) 'fixed-pitch)
              ;; Disable whitespace mode if enabled.
              (setq show-trailing-whitespace nil)
              (if global-whitespace-mode
                  (whitespace-mode))
              (buffer-face-mode t))))

;; (use-package multi-vterm
;;   :straight (:host github :repo "suonlight/multi-vterm" :branch "master"))

;; (use-package vterm-toggle
;;   :straight (:host github :repo "jixiuf/vterm-toggle" :branch "master"))

(use-package notmuch
  :ensure t
  :config
  (defun notmuch-mail-sync ()
    "Synchronize mail"
    (interactive)
    (set-process-sentinel
     (let ((compile-buffer
	    (compile "${HOME}/bin/sync-mail.sh" t)))
       (with-current-buffer compile-buffer
         (rename-buffer "*mail-sync*")
	 (display-buffer (current-buffer))))
     '(lambda (process event)
        (notmuch-refresh-all-buffers)
        (let ((w (get-buffer-window "*mail-sync*")))
          (when w
            (with-selected-window w (recenter (window-end))))))))

  (define-key ctl-x-map "M" #'notmuch-mail-sync)
  (define-key ctl-x-map "N" #'notmuch)

  ;; Per-address Fcc directories are identity specific; overlays add
  ;; entries to `notmuch-fcc-dirs'.
  (setq notmuch-fcc-dirs nil)

  (defvar notmuch-hello-refresh-count 0)

  (defun notmuch-hello-refresh-status-message ()
    (unless no-display
      (let* ((new-count
              (string-to-number
               (car (process-lines notmuch-command "count"))))
             (diff-count (- new-count notmuch-hello-refresh-count)))
        (cond
         ((= notmuch-hello-refresh-count 0)
          (message "You have %s messages."
                   (notmuch-hello-nice-number new-count)))
         ((> diff-count 0)
          (message "You have %s more messages since last refresh."
                   (notmuch-hello-nice-number diff-count)))
         ((< diff-count 0)
          (message "You have %s fewer messages since last refresh."
                   (notmuch-hello-nice-number (- diff-count)))))
        (setq notmuch-hello-refresh-count new-count))))

  (add-hook 'notmuch-hello-refresh-hook 'notmuch-hello-refresh-status-message)

  (defun notmuch-show-subject-tabs-to-spaces ()
    "Replace tabs with spaces in subject line."
    (goto-char (point-min))
    (when (re-search-forward "^Subject:" nil t)
      (while (re-search-forward "\t" (line-end-position) t)
        (replace-match " " nil nil))))

  (add-hook 'notmuch-show-markup-headers-hook 'notmuch-show-subject-tabs-to-spaces)

  (defun notmuch-show-header-tabs-to-spaces ()
    "Replace tabs with spaces in header line."
    (setq header-line-format
          (notmuch-show-strip-re
           (replace-regexp-in-string "\t" " " (notmuch-show-get-subject)))))

  (add-hook 'notmuch-show-hook 'notmuch-show-header-tabs-to-spaces)

  ;; View diffs in notmuch
  (defun my-notmuch-show-view-as-patch ()
    "View the the current message as a patch."
    (interactive)
    (let* ((id (notmuch-show-get-message-id))
           (msg (notmuch-show-get-message-properties))
           (part (notmuch-show-get-part-properties))
           (subject (concat "Subject: " (notmuch-show-get-subject) "\n"))
           (diff-default-read-only t)
           (buf (get-buffer-create (concat "*notmuch-patch-" id "*")))
           (map (make-sparse-keymap)))
      (define-key map "q" 'notmuch-bury-or-kill-this-buffer)
      (switch-to-buffer buf)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert subject)
        (insert (notmuch-get-bodypart-text msg part nil)))
      (set-buffer-modified-p nil)
      (diff-mode)
      (let ((new-ro-bind (cons 'buffer-read-only map)))
        (add-to-list 'minor-mode-overriding-map-alist new-ro-bind))
      (goto-char (point-min))))

  (defun my-notmuch-add-search (name key search type)
    "Add a saved search NAME invokable with KEY using SEARCH as the
query presenting results according to TYPE."
    (set (intern (concat "notmuch-" name "-search")) search)
    (set (intern (concat "notmuch-" name "-search-key")) key)
    (add-to-list 'notmuch-saved-searches `(:name ,name :query ,(symbol-value (intern (concat "notmuch-" name "-search"))) :key  ,(symbol-value (intern (concat "notmuch-" name "-search-key"))) :search-type ,type))
    (define-key notmuch-hello-mode-map (symbol-value (intern (concat "notmuch-" name "-search-key")))
      (lambda ()
        (concat "Search for all " name " mail")
        (interactive)
        (notmuch-search (symbol-value (intern (concat "notmuch-" name "-search")))))))

  (define-key 'notmuch-show-part-map "d" 'my-notmuch-show-view-as-patch)

  (my-notmuch-add-search "unread" "u" "tag:unread" 'tree)
  (my-notmuch-add-search "unprocessed" "U" "tag:unprocessed" 'tree)
  (my-notmuch-add-search "inbox" "i" "tag:inbox and tag:unread" 'tree)
  ;; Employer-, mailing-list-, and personal-specific saved searches are
  ;; added by overlays.
  (my-notmuch-add-search "trash" "T" "tag:trash" 'tree)


  (define-key notmuch-show-mode-map "\C-c\C-o" 'browse-url-at-point)

  (define-key notmuch-search-mode-map "g"
    'notmuch-poll-and-refresh-this-buffer)
  (define-key notmuch-hello-mode-map "g"
    'notmuch-poll-and-refresh-this-buffer)

  (setq notmuch-view-delete-key "d"
        notmuch-view-trash-key "T"
        notmuch-view-unread-key "!"
        notmuch-view-unprocessed-key "U"
        notmuch-view-archive-key "a")

  (defun notmuch-define-view-key (map key action)
    "Define KEY in MAP for ACTION"
    (define-key map key action))

  (defun notmuch-define-toggle-key-in-map
      (map key tag search-func update-func &rest extra-actions)
    "Define KEY in MAP to toggle TAG using SEARCH-FUNC and
UPDATE-FUNC.  Remove the unread and unprocessed tags and perform
any EXTRA-ACTIONS."
    (notmuch-define-view-key map key
                             (let ((captured-key key)
                                           (captured-tag tag)
                                           (captured-search-func search-func)
                                           (captured-update-func update-func)
                                           (captured-extra-actions extra-actions))
                               (lambda ()
                                 (interactive)
                                 (let* ((delete-tag
                                         `(,(concat "-" captured-tag)))
                                        (delete-tag-actions delete-tag)
                                        (set-tag `(,(concat "+" captured-tag)
                                                   "-unprocessed"))
                                        (set-tag-actions
                                         (append set-tag captured-extra-actions)))
                                   (message (format "delete-tag: %s" delete-tag))
                                   (message (format "set-tag: %s" set-tag))
                                   (message (format "captured-extra-actions: %s" captured-extra-actions))
                                   (message (format "delete-tag-actions: %s" delete-tag-actions))
                                   (message (format "set-tag-actions: %s" set-tag-actions))
                                   (if
                                       (member captured-tag
                                               (funcall captured-search-func))
                                       (funcall captured-update-func
                                                delete-tag-actions)
                                     (funcall captured-update-func
                                              set-tag-actions)))))))

  (defun notmuch-define-toggle-key (key tag &rest extra-actions)
    "Define KEY to toggle TAG in show, search and tree modes"
    (apply #'notmuch-define-toggle-key-in-map
           notmuch-search-mode-map
           key
           tag
           'notmuch-search-get-tags
           'notmuch-search-tag
           extra-actions)
    (apply #'notmuch-define-toggle-key-in-map
           notmuch-tree-mode-map
           key
           tag
           'notmuch-tree-get-tags
           'notmuch-tree-tag
           extra-actions)
    (apply #'notmuch-define-toggle-key-in-map
           notmuch-show-mode-map
           key
           tag
           'notmuch-show-get-tags
           'notmuch-show-tag
           extra-actions))

  (notmuch-define-toggle-key notmuch-view-delete-key
                             "deleted"
                             "-unread"
                             "-inbox")

  (notmuch-define-toggle-key notmuch-view-trash-key
                             "trash"
                             "-unread"
                             "-inbox")

  (notmuch-define-toggle-key notmuch-view-unread-key
                             "unread")

  (notmuch-define-toggle-key notmuch-view-unprocessed-key
                             "unprocessed")

  (notmuch-define-toggle-key notmuch-view-archive-key
                             "archive"
                             "-unread"
                             "-inbox"))

(use-package paren
  :ensure nil
  :config
  (show-paren-mode +1))

(use-package elec-pair
  :ensure nil
  :config
  (electric-pair-mode +1))

(use-package abbrev
  :ensure nil
  :config
  (setq save-abbrevs 'silently)
  (setq-default abbrev-mode t))

(use-package uniquify
  :ensure nil
  :config
  (setq uniquify-buffer-name-style 'forward)
  (setq uniquify-separator "/")
  ;; rename after killing uniquified
  (setq uniquify-after-kill-buffer-p t)
  ;; don't muck with special buffers
  (setq uniquify-ignore-buffers-re "^\\*"))

;; ;; saveplace remembers your location in a file when saving files
;; (use-package saveplace
;;   :config
;;   (setq save-place-file (expand-file-name "saveplace" bozhidar-savefile-dir))
;;   ;; activate it for all buffers
;;   (setq-default save-place t))

;; (use-package recentf
;;   :config
;; (defconst bozhidar-savefile-dir (expand-file-name "savefile" user-emacs-directory))

;; create the savefile dir if it doesn't exist
;;
;; (unless (file-exists-p bozhidar-savefile-dir)
;;   (make-directory bozhidar-savefile-dir))

;;   (setq recentf-save-file (expand-file-name "recentf" bozhidar-savefile-dir)
;;         recentf-max-saved-items 500
;;         recentf-max-menu-items 15
;;         ;; disable recentf-cleanup on Emacs start, because it can cause
;;         ;; problems with remote files
;;         recentf-auto-cleanup 'never)
;;   (recentf-mode +1))

;; (use-package windmove
;;   :config
;;   ;; use shift + arrow keys to switch between visible buffers
;;   (windmove-default-keybindings))

(use-package dired
  :ensure nil
  :config
  ;; dired - reuse current buffer by pressing 'a'
  (put 'dired-find-alternate-file 'disabled nil)

  ;; always delete and copy recursively
  ;;(setq dired-recursive-deletes 'always)
  ;;(setq dired-recursive-copies 'always)

  ;; if there is a dired buffer displayed in the next window, use its
  ;; current subdir, instead of the current subdir of this dired buffer
  (setq dired-dwim-target t)

  ;; enable some really cool extensions like C-x C-j(dired-jump)
  (require 'dired-x))

;; (use-package rainbow-delimiters
;;   :straight t
;;   :hook (prog-mode . rainbow-delimiters-mode))

;; (use-package rainbow-mode
;;   :straight t
;;   :hook (prog-mode . rainbow-mode))

(use-package lisp-mode
  :ensure nil
  :config
  (defun bozhidar-visit-ielm ()
    "Switch to default `ielm' buffer.
Start `ielm' if it's not already running."
    (interactive)
    (crux-start-or-switch-to 'ielm "*ielm*"))

  (add-hook 'emacs-lisp-mode-hook #'eldoc-mode)
  ;;(add-hook 'emacs-lisp-mode-hook #'rainbow-delimiters-mode)
  (define-key emacs-lisp-mode-map (kbd "C-c C-z") #'bozhidar-visit-ielm)
  (define-key emacs-lisp-mode-map (kbd "C-c C-c") #'eval-defun)
  (define-key emacs-lisp-mode-map (kbd "C-c C-b") #'eval-buffer)
  (add-hook 'lisp-interaction-mode-hook #'eldoc-mode)
  (add-hook 'eval-expression-minibuffer-setup-hook #'eldoc-mode))

(use-package ielm
  :ensure nil
  :config
  (add-hook 'ielm-mode-hook #'eldoc-mode)
  ;;(add-hook 'ielm-mode-hook #'rainbow-delimiters-mode)
  )

(require 'auth-source)

(setq auth-sources '(password-store))

;; Third-party packages

;; (use-package crux
;;   :straight t
;;   :bind (("C-c o" . crux-open-with)
;;          ("M-o" . crux-smart-open-line)
;;          ("C-c n" . crux-cleanup-buffer-or-region)
;;          ("C-c f" . crux-recentf-find-file)
;;          ("C-M-z" . crux-indent-defun)
;;          ("C-c u" . crux-view-url)
;;          ("C-c e" . crux-eval-and-replace)
;;          ("C-c w" . crux-swap-windows)
;;          ("C-c D" . crux-delete-file-and-buffer)
;;          ("C-c r" . crux-rename-buffer-and-file)
;;          ("C-c t" . crux-visit-term-buffer)
;;          ("C-c k" . crux-kill-other-buffers)
;;          ("C-c TAB" . crux-indent-rigidly-and-copy-to-clipboard)
;;          ("C-c I" . crux-find-user-init-file)
;;          ("C-c S" . crux-find-shell-init-file)
;;          ("s-r" . crux-recentf-find-file)
;;          ("s-j" . crux-top-join-line)
;;          ("C-^" . crux-top-join-line)
;;          ("s-k" . crux-kill-whole-line)
;;          ("C-<backspace>" . crux-kill-line-backwards)
;;          ("s-o" . crux-smart-open-line-above)
;;          ([remap move-beginning-of-line] . crux-move-beginning-of-line)
;;          ([(shift return)] . crux-smart-open-line)
;;          ([(control shift return)] . crux-smart-open-line-above)
;;          ([remap kill-whole-line] . crux-kill-whole-line)
;;          ("C-c s" . crux-ispell-word-then-abbrev)))

;; ; The Silver Searcher
;; (use-package ag
;;   :straight t)

;; ; The Platinum Searcher
;; (use-package pt
;;   :straight t)

;; (use-package expand-region
;;   :straight t
;;   :bind ("C-=" . er/expand-region))

(use-package elisp-slime-nav
  :ensure t
  :config
  (dolist (hook '(emacs-lisp-mode-hook ielm-mode-hook))
    (add-hook hook #'elisp-slime-nav-mode)))

; Display current match and total matches in mode-line
;; (use-package anzu
;;   :straight t
;;   :bind (("M-%" . anzu-query-replace)
;;          ("C-M-%" . anzu-query-replace-regexp)))

;; (use-package easy-kill
;;   :straight t
;;   :config
;;   (global-set-key [remap kill-ring-save] 'easy-kill)
;;   (global-set-key [remap mark-sexp] 'easy-mark))

;; (use-package move-text
;;   :straight t
;;   :bind
;;   (([(meta shift up)] . move-text-up)
;;    ([(meta shift down)] . move-text-down)))

(use-package markdown-mode
  :ensure t
  :mode (("\\.md\\'" . gfm-mode)
         ("\\.markdown\\'" . gfm-mode))
  :config
  (setq markdown-fontify-code-blocks-natively t)
  :preface
  (defun jekyll-insert-image-url ()
    (interactive)
    (let* ((files (directory-files "../assets/images"))
           (selected-file (completing-read "Select image: " files nil t)))
      (insert (format "![%s](/assets/images/%s)" selected-file selected-file))))

  (defun jekyll-insert-post-url ()
    (interactive)
    (let* ((files (remove "." (mapcar #'file-name-sans-extension (directory-files "."))))
           (selected-file (completing-read "Select article: " files nil t)))
      (insert (format "{%% post_url %s %%}" selected-file)))))

;; (use-package adoc-mode
;;   :straight t
;;   :mode "\\.adoc\\'")

(use-package hl-todo
  :ensure t
  :config
  (setq hl-todo-highlight-punctuation ":")
  (global-hl-todo-mode))

;; (use-package zop-to-char
;;   :straight t
;;   :bind (("M-z" . zop-up-to-char)
;;          ("M-Z" . zop-to-char)))

;; (use-package imenu-anywhere
;;   :straight t
;;   :bind (("s-i" . imenu-anywhere)))

;;(use-package diff-hl
;;  :straight t
;;  :config
;;  (global-diff-hl-mode +1)
;;  (add-hook 'dired-mode-hook 'diff-hl-dired-mode)
;;  (add-hook 'magit-post-refresh-hook 'diff-hl-magit-post-refresh))

;; (use-package undo-tree
;;   :straight t
;;   :config
;;   ;; autosave the undo-tree history
;;   (setq undo-tree-history-directory-alist
;;         `((".*" . ,temporary-file-directory)))
;;   (setq undo-tree-auto-save-history t))

;; (use-package ace-window
;;   :straight t
;;   :config
;;   (global-set-key (kbd "s-w") 'ace-window)
;; ;  (global-set-key [remap other-window] 'ace-window)
;;   )

;; temporarily highlight changes from yanking, etc
(use-package volatile-highlights
  :ensure t
  :config
  (volatile-highlights-mode +1))

(use-package treemacs
  :ensure t
  :defer t
  :config
  (progn
    ;; The default width and height of the icons is 22 pixels. If you are
    ;; using a Hi-DPI display, uncomment this to double the icon size.
    ;;(treemacs-resize-icons 44)

    (treemacs-follow-mode t)
    (treemacs-filewatch-mode t)
    (treemacs-fringe-indicator-mode t)))

;; (use-package treemacs-evil
;;   :after treemacs evil
;;   :ensure t)

;; (use-package projectile
;;  :straight t
;;  :bind (:map projectile-mode-map
;;              ("s-p" . projectile-command-map))
;;  :init
;;  (projectile-mode +1)
;;  :config
;;  (setq projectile-completion-system 'ivy))

;; (use-package treemacs-projectile
;;   :straight t
;;   :ensure t)

;; (use-package counsel-projectile
;;   :straight t
;;   :config
;;   (counsel-projectile-mode))

;; (use-package helm-projectile
;;   :requires (helm projectile)
;;   :straight t
;;   :config
;;   (setq projectile-completion-system 'helm)
;;   (helm-projectile-on))

(use-package ag
;;  :straight t
  )

;; (use-package treemacs-icons-dired
;;   :after treemacs dired
;;   :straight t
;;   :config (treemacs-icons-dired-mode))

;; (use-package treemacs-magit
;;   :after treemacs magit
;;   :straight t)

;; (use-package aggressive-indent
;;   :straight t
;;   :hook (prog-mode . aggressive-indent-mode))

;; (require 'tramp-sh)
(use-package tramp-term
  :ensure t
  )

;; ;;(require 'psvn)

;; elpaca error
;; (use-package ldap
;; ;;  :straight t
;;   )

;; elpaca error, also a duplicate
;; (use-package eudc
;; ;;  :straight t
;;   )

(use-package cmake-mode
  :ensure t
  )

(use-package cmake-font-lock
  :ensure t
  :hook cmake-mode)

(use-package password-store-otp
  :ensure (:fetcher github :repo "volrath/password-store-otp.el" :tag "0.1.5")
  )

(use-package password-store
  :ensure t
  )

(use-package pass
  :ensure t
  )

(use-package auth-source-pass
  ;;  :straight t
  :ensure nil
  )

(use-package boxquote
;;  :straight t
  )

;; (use-package rmsbolt
;;   :straight t)

;; (use-package all-the-icons
;;   :straight t
;;   :init
;;   (unless (member "all-the-icons" (font-family-list))
;;     (all-the-icons-install-fonts t)))

;; (use-package pdf-tools
;;   :straight t
;;   :config (pdf-loader-install))

;; ---------------------------------------------------------------------
;; C indent mode
;;
(use-package cc-styles
  :ensure nil
  :init
  (defconst llvm-c-style
    '((c-tab-always-indent        . t)
      (c-comment-only-line-offset . 4)
      (c-basic-offset . 2)
      (c-hanging-braces-alist . ((brace-list-open after)
				 (brace-entry-open after)
                                 (defun-open after)
				 (class-open after)
				 (inline-open after)
				 (statement-cont)
				 (substatement-open after)
				 (block-open after)
				 (block-close . c-snug-do-while)
				 (statement-case-open after)
				 (substatement-open after)
				 (namespace-open after)
				 (extern-lang-open after)
				 (inexpr-class-open after)
				 (inexpr-class-close before)))
      (c-hanging-colons-alist . ((case-label after)
				 (access-label after)
				 (label after)
				 (member-init-intro before)
				 (inher-intro before)))
      (c-cleanup-list . (empty-defun-braces
			 defun-close-semi
			 list-close-comma
			 compact-empty-funcall
			 scope-operator))
      (c-offsets-alist . ((string . -1000)
			  (c . c-lineup-C-comments)
			  (defun-open . 0)
			  (defun-close . 0)
			  (defun-block-intro . +)
			  (class-open . 0)
			  (class-close . 0)
			  (inline-open . 0)
			  (inline-close . 0)
			  (func-decl-cont . +)
			  (knr-argdecl-intro . +)
			  (knr-argdecl . 0)
			  (topmost-intro . 0)
			  (topmost-intro-cont . 0)
			  (member-init-intro . ++)
			  (member-init-cont . +)
			  (inher-intro . ++)
			  (inher-cont . +)
			  (block-open . 0)
			  (block-close . 0)
			  (brace-list-open . 0)
			  (brace-list-close . 0)
			  (brace-list-intro . +)
			  (brace-list-entry . 0)
			  (brace-entry-open . +)
			  (statement . 0)
			  (statement-cont . +)
			  (statement-block-intro . +)
			  (statement-case-intro . +)
			  (statement-case-open . 0)
			  (substatement . +)
			  (substatement-open . 0)
			  (case-label . 0)
			  (access-label . -)
			  (label . -1000)
			  (do-while-closure . 0)
			  (else-clause . 0)
			  (catch-clause . 0)
			  (comment-intro . 0)
			  ;;			(arglist-intro . c-lineup-arglist)
			  ;;			(arglist-cont . c-lineup-arglist)
			  (arglist-intro . +)
			  (arglist-cont . 0)
			  (arglist-cont-nonempty . c-lineup-arglist)
			  (arglist-close . c-lineup-arglist)
			  (stream-op . +)
			  (inclass . +)
			  (cpp-macro . -1000)
			  (cpp-macro-cont . 0)
			  (friend . 0)
			  (objc-method-intro . +)
			  (objc-method-args-cont . 0)
			  (objc-method-call-cont . +)
			  (extern-lang-open . 0)
			  (extern-lang-close . 0)
			  (inextern-lang . +)
			  (namespace-open . 0)
			  (namespace-close . 0)
			  (innamespace . +)
					;			(module-open . 0)
					;			(module-close . 0)
					;			(inmodule . +)
					;			(composition-open . 0)
					;			(composition-close . 0)
					;			(incomposition . +)
			  (template-args-cont . +)
			  (inlambda . +)
			  (lambda-intro-cont . +)
			  (inexpr-statement . +)
			  (inexpr-class . +))))
    "Default LLVM C Style")

					;			(substatement-label . /)
					;			(cpp-define-intro . +)

  ;; git's coding style is essentially the Linux kernel style: 8-column
  ;; indentation with tabs.  Base it on the built-in "linux" style so the
  ;; public config is self-contained.
  (defconst git-c-style
    '("linux"
      (c-basic-offset . 8)
      (indent-tabs-mode . t))
    "git C Style")

					;			(cpp-define-intro . +)
					;			(substatement-label . /)

                                        ; Who knew the defaults didn't ensure tabs were set correctly.  From
                                        ; Documentation/CodingStyle Chapter 9

  (defun c-lineup-arglist-tabs-only (ignored)
    "Line up argument lists by tabs, not spaces"
    (let* ((anchor (c-langelem-pos c-syntactic-element))
	   (column (c-langelem-2nd-pos c-syntactic-element))
	   (offset (- (1+ column) anchor))
	   (steps (floor offset c-basic-offset)))
      (* (max steps 1)
	 c-basic-offset)))

  (defconst linux-tabs-style
    '("linux"
      (indent-tabs-mode . t)
      (c-offsets-alist
       (arglist-cont-nonempty
	c-lineup-gcc-asm-reg
	c-lineup-arglist-tabs-only))))

  :config
  (progn
    ;; Personal styles (e.g. my-c-style) are registered by overlays.
    (c-add-style "git-c-style" git-c-style)
    (c-add-style "linux-tabs-style" linux-tabs-style)))

(use-package bison-mode
;;  :straight t
  :mode "\\(\\.yy\\|\\.y\\)\\'")

(use-package sphinx-doc
;;  :straight t
  :config
  (add-hook 'python-mode-hook (lambda ()
                                (require 'sphinx-doc)
                                (sphinx-doc-mode t))))

(use-package cc-mode
  :ensure nil
  :init
  (defconst my-c-lineup-maximum-indent 30)

  ;; For short function names, use standard indent.  For long function
  ;; names, do something intelligent.

  (defun my-c-lineup-arglist (langelem)
    (let ((ret (c-lineup-arglist langelem)))
      (if (< (elt ret 0) my-c-lineup-maximum-indent)
	  ret
	(save-excursion
	  (goto-char (cdr langelem))
	  (vector (+ (current-column) 8))))))

  ;;(defun my-indent-setup ()
  ;;  (setcdr (assoc 'arglist-cont-nonempty c-offsets-alist)
  ;;	  '(c-lineup-gcc-asm-reg my-c-lineup-arglist)))


  ;;
  ;; cc-styles
  ;;
  ;; Add the style definitions on demand when we load it
  ;; my-c-style-guesser
					;  
  (defvar my-c-styles-alist
    (mapc
     (lambda (elt)
       (cons (purecopy (car elt)) (cdr elt)))
     '(
       (".*/linux.*/.*\\.[ch]$" . "linux")  
       (".*/.*kernel.*/.*\\.[ch]$" . "linux")
       (".*/.*linux/.*\\.[ch]$" . "linux")
       ;;(".*/.*llvm/.*\\.[ch]$" . "llvm-c-style")
       (".*binutils.*\\.[ch]$"  . "gnu")
       (".*git.*\\.[ch]$"  . "git-c-style")
       (".*gtk-gnutella.*"      . "gtkg-style")
       (".*rockbox.*\\.[ch]$"   . "rockbox-c-style")
       (".*mysrc.*\\.[ch]$"     . "my-c-style")
       (".*easytag.*/src/.*\\.[ch]$". "easytag-c-style")))
    "A list of reg-ex to styles for my-c-style-guesser")

  ; You can add to the alist with something like:
  ; (setq my-c-styles-alist (cons '(".*mysrc.*$" . my-c-style) my-c-styles-alist))
  ; (setq my-c-styles-alist (cons '(".*easytag.*/src/.*\\.[ch]$". "easytag-c-style") my-c-styles-alist))

  (defun my-c-style-guesser(filename)
    "Guess the C style we should use based on the path of the buffer"
    (message (concat "my-c-style-guesser " filename))
    (assoc-default filename my-c-styles-alist 'string-match))

  ; examples
  ; (my-c-style-guesser "/home/alex/src/kernel/linux-2.6/drivers/ide/ide-cd.c")
  ; (my-c-style-guesser "/home/alex/mysrc/mysrc.old/c/binmerge/binmerge.c")

  ;;  (setq c++-friend-offset 0))

  ;; put 'em in
  ;;(add-hook 'text-mode-hook 'my/text-mode-hook)

  (defun my/c-mode-hook () "Startup options for C mode"
	 (c-toggle-auto-hungry-state 1)	; Auto-newline mode
	 (setq indent-tabs-mode nil)		; Use spaces instead of tabs
	 (setq c-echo-syntactic-information-p t)
	 (setq c-auto-align-backslashes t)
	 '(lambda ()
	    (gtags-mode 1)
	    )
         ; Set the c-style if we can. I think mmm-mode gets in the way
         ; of buffer-file-name for setting sub-modes, so check we have
         ; one first
	 (when buffer-file-name
	   (message (format "looking for style for buffer %s" (buffer-file-name)))
	   (let ((style (my-c-style-guesser (buffer-file-name))))
	     (when style
	       (message (format "my-c-mode-hook: found style %s" style))
	       (c-set-style style))))

	 ;; (cwarn-mode) ; Warns too much for C++.
	 )

  (defun my/c++-mode-hook () "Startup options for C++ mode"
	 (run-hooks 'my/c-mode-hook))
  :config
  (progn
    (add-hook 'c-mode-common-hook 'my/c-mode-hook)
    (add-hook 'c-mode-common-hook 'subword-mode)
    (add-hook 'c++-mode-common-hook 'my/c++-mode-hook)
    (add-hook 'c++-mode-common-hook 'subword-mode)
    (define-key c-mode-map (kbd "C-c f") 'find-tag)
    ))

;; elpaca error
;; (use-package etags-select
;;   :ensure nil
;;   :init (define-key c-mode-map (kbd "C-c f") 'etags-select-find-tag))

(use-package paredit
  :ensure t
  :config
  (add-hook 'emacs-lisp-mode-hook #'paredit-mode)
  ;; enable in the *scratch* buffer
  (add-hook 'lisp-interaction-mode-hook #'paredit-mode)
  (add-hook 'ielm-mode-hook #'paredit-mode)
  (add-hook 'lisp-mode-hook #'paredit-mode)
  (add-hook 'eval-expression-minibuffer-setup-hook #'paredit-mode))

;; (use-package flyspell
;;   :straight t
;;   :config
;;   (setq ispell-program-name "aspell" ; use aspell instead of ispell
;;         ispell-extra-args '("--sug-mode=ultra"))
;;   (add-hook 'text-mode-hook #'flyspell-mode)
;;   (add-hook 'prog-mode-hook #'flyspell-prog-mode))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; lsp infrastructure
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; (use-package flycheck
;;   :straight t
;;   :ensure t
;;   :init (global-flycheck-mode))

;; (use-package lsp-ui
;;  :straight t
;;  :commands lsp-ui-mode)

;; (use-package lsp-treemacs
;;  :straight t
;;  :config
;;  (lsp-treemacs-sync-mode 1))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Ivy infrastructure
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; (use-package ivy
;;   :straight t
;;   :diminish
;;   :bind (("C-c C-r" . ivy-resume)
;;          ("C-x B" . ivy-switch-buffer-other-window))
;;   :config
;;   (ivy-mode 1)
;;   (setq ivy-use-virtual-buffers t)
;;   (setq enable-recursive-minibuffers t))

;; (use-package swiper
;;   :straight t
;;   ;;:after ivy
;;   :bind (("C-s" . swiper)
;;          ("C-r" . swiper)))

;; Slows down TRAMP tremendously
;;
;; (use-package all-the-icons-ivy
;;   :straight t
;;   :config
;;   (all-the-icons-ivy-setup))

;; (use-package ivy-pass
;;   :straight t)

;; (use-package ivy-rich
;;   :straight t
;;   :after ivy
;;   :custom
;;   (ivy-virtual-abbreviate 'full
;;                           ivy-rich-switch-buffer-align-virtual-buffer t
;;                           ivy-rich-path-style 'abbrev)
;;   :config
;;   (ivy-set-display-transformer 'ivy-switch-buffer
;;                                'ivy-rich-switch-buffer-transformer))

;; (use-package counsel
;;   :straight t
;;   ;;:after ivy
;;   :config
;;   (counsel-mode)
;;   (global-set-key (kbd "M-x") 'counsel-M-x)
;;   (global-set-key (kbd "C-x C-f") 'counsel-find-file)
;;   (global-set-key (kbd "<f1> f") 'counsel-describe-function)
;;   (global-set-key (kbd "<f1> v") 'counsel-describe-variable)
;;   (global-set-key (kbd "<f1> l") 'counsel-find-library)
;;   (global-set-key (kbd "<f2> i") 'counsel-info-lookup-symbol)
;;   (global-set-key (kbd "<f2> u") 'counsel-unicode-char)
;;   (global-set-key (kbd "C-c g") 'counsel-git)
;;   (global-set-key (kbd "C-c j") 'counsel-git-grep)
;;   (global-set-key (kbd "C-c a") 'counsel-ag)
;;   (global-set-key (kbd "C-x l") 'counsel-locate)
;;   (define-key minibuffer-local-map (kbd "C-r") 'counsel-minibuffer-history))

;; (use-package flx
;;   :straight t
;;   :config
;;   ;; (setq ivy-re-builders-alist
;;   ;;       '((t . ivy--regex-fuzzy)))
;;   (setq ivy-re-builders-alist
;;         '((t . ivy--regex-plus)))
;;   (setq ivy-initial-alist-inputs nil))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Vertico infrastructure
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(use-package vertico
  :ensure t
  :init
  (vertico-mode)

  ;; Different scroll margin
  ;; (setq vertico-scroll-margin 0)

  ;; Show more candidates
  ;; (setq vertico-count 20)

  ;; Grow and shrink the Vertico minibuffer
  ;; (setq vertico-resize t)

  ;; Optionally enable cycling for `vertico-next' and `vertico-previous'.
  ;; (setq vertico-cycle t)

  ;; Option 1: Additional bindings
  (keymap-set vertico-map "?" #'minibuffer-completion-help)
  (keymap-set vertico-map "M-RET" #'minibuffer-force-complete-and-exit)
  (keymap-set vertico-map "M-TAB" #'minibuffer-complete)

  ;; Option 2: Replace `vertico-insert' to enable TAB prefix expansion.
  ;; (keymap-set vertico-map "TAB" #'minibuffer-complete)
  )

;; Persist history over Emacs restarts. Vertico sorts by history position.
(use-package savehist
  :ensure nil
  :init
  (savehist-mode))

;; (use-package savehist
;;   :config
;;   (setq savehist-additional-variables
;;         ;; search entries
;;         '(search-ring regexp-search-ring)
;;         ;; save every minute
;;         savehist-autosave-interval 60
;;         ;; keep the home clean
;;         savehist-file (expand-file-name "savehist" bozhidar-savefile-dir))
;;   (savehist-mode +1))

;; Optionally use the `orderless' completion style.
(use-package orderless
  :ensure t
  :init
  ;; Configure a custom style dispatcher (see the Consult wiki)
  ;; (setq orderless-style-dispatchers '(+orderless-consult-dispatch orderless-affix-dispatch)
  ;;       orderless-component-separator #'orderless-escapable-split-on-space)
  (setq completion-styles '(orderless basic)
        completion-category-defaults nil
        completion-category-overrides '((file (styles partial-completion)))))

;; Enable rich annotations using the Marginalia package
(use-package marginalia
  :ensure t

  ;; Bind `marginalia-cycle' locally in the minibuffer.  To make the binding
  ;; available in the *Completions* buffer, add it to the
  ;; `completion-list-mode-map'.
  :bind (:map minibuffer-local-map
              ("M-A" . marginalia-cycle))

  ;; The :init section is always executed.
  :init

  ;; Marginalia must be activated in the :init section of use-package such that
  ;; the mode gets enabled right away. Note that this forces loading the
  ;; package.
  (marginalia-mode))

;; (use-package all-the-icons-completion
;;   :straight t
;;   :config
;;   (add-hook 'marginalia-mode-hook #'all-the-icons-completion-marginalia-setup)
;;   (all-the-icons-completion-mode))

;; (use-package nerd-icons-completion
;;   :straight t
;;   :config
;;   (add-hook 'marginalia-mode-hook #'nerd-icons-completion-marginalia-setup)
;;   (nerd-icons-completion-mode))

;; Example configuration for Consult
(use-package consult
  :ensure t
  ;; Replace bindings. Lazily loaded due by `use-package'.
  :bind (;; C-c bindings in `mode-specific-map'
         ("C-c M-x" . consult-mode-command)
         ("C-c h" . consult-history)
         ("C-c k" . consult-kmacro)
         ;;("C-c m" . consult-man)
         ("C-c i" . consult-info)
         ([remap Info-search] . consult-info)
         ;; C-x bindings in `ctl-x-map'
         ("C-x M-:" . consult-complex-command) ;; orig. repeat-complex-command
         ("C-x b" . consult-buffer)            ;; orig. switch-to-buffer
         ("C-x 4 b" . consult-buffer-other-window) ;; orig. switch-to-buffer-other-window
         ("C-x 5 b" . consult-buffer-other-frame) ;; orig. switch-to-buffer-other-frame
         ("C-x t b" . consult-buffer-other-tab) ;; orig. switch-to-buffer-other-tab
         ("C-x r b" . consult-bookmark)         ;; orig. bookmark-jump
         ("C-x p b" . consult-project-buffer) ;; orig. project-switch-to-buffer
         ;; Custom M-# bindings for fast register access
         ("M-#" . consult-register-load)
         ("M-'" . consult-register-store) ;; orig. abbrev-prefix-mark (unrelated)
         ("C-M-#" . consult-register)
         ;; Other custom bindings
         ("M-y" . consult-yank-pop) ;; orig. yank-pop
         ;; M-g bindings in `goto-map'
         ("M-g e" . consult-compile-error)
         ("M-g f" . consult-flymake)     ;; Alternative: consult-flycheck
         ("M-g g" . consult-goto-line)   ;; orig. goto-line
         ("M-g M-g" . consult-goto-line) ;; orig. goto-line
         ("M-g o" . consult-outline)     ;; Alternative: consult-org-heading
         ("M-g m" . consult-mark)
         ("M-g k" . consult-global-mark)
         ("M-g i" . consult-imenu)
         ("M-g I" . consult-imenu-multi)
         ;; M-s bindings in `search-map'
         ("M-s d" . consult-find) ;; Alternative: consult-fd
         ("M-s c" . consult-locate)
         ("M-s g" . consult-grep)
         ("M-s G" . consult-git-grep)
         ("M-s r" . consult-ripgrep)
         ("M-s l" . consult-line)
         ("M-s L" . consult-line-multi)
         ("M-s k" . consult-keep-lines)
         ("M-s u" . consult-focus-lines)
         ;; Isearch integration
         ("M-s e" . consult-isearch-history)
         :map isearch-mode-map
         ("M-e" . consult-isearch-history)   ;; orig. isearch-edit-string
         ("M-s e" . consult-isearch-history) ;; orig. isearch-edit-string
         ("M-s l" . consult-line) ;; needed by consult-line to detect isearch
         ("M-s L" . consult-line-multi) ;; needed by consult-line to detect isearch
         ;; Minibuffer history
         :map minibuffer-local-map
         ("M-s" . consult-history)  ;; orig. next-matching-history-element
         ("M-r" . consult-history)) ;; orig. previous-matching-history-element

  ;; Enable automatic preview at point in the *Completions* buffer. This is
  ;; relevant when you use the default completion UI.
  :hook (completion-list-mode . consult-preview-at-point-mode)

  ;; The :init configuration is always executed (Not lazy)
  :init

  ;; Optionally configure the register formatting. This improves the register
  ;; preview for `consult-register', `consult-register-load',
  ;; `consult-register-store' and the Emacs built-ins.
  (setq register-preview-delay 0.5
        register-preview-function #'consult-register-format)

  ;; Optionally tweak the register preview window.
  ;; This adds thin lines, sorting and hides the mode line of the window.
  (advice-add #'register-preview :override #'consult-register-window)

  ;; Use Consult to select xref locations with preview
  (setq xref-show-xrefs-function #'consult-xref
        xref-show-definitions-function #'consult-xref)

  ;; Configure other variables and modes in the :config section,
  ;; after lazily loading the package.
  :config

  ;; Optionally configure preview. The default value
  ;; is 'any, such that any key triggers the preview.
  ;; (setq consult-preview-key 'any)
  ;; (setq consult-preview-key "M-.")
  ;; (setq consult-preview-key '("S-<down>" "S-<up>"))
  ;; For some commands and buffer sources it is useful to configure the
  ;; :preview-key on a per-command basis using the `consult-customize' macro.
  (consult-customize
   consult-theme :preview-key '(:debounce 0.2 any)
   consult-ripgrep consult-git-grep consult-grep
   consult-bookmark consult-recent-file consult-xref
   consult--source-bookmark consult--source-file-register
   consult--source-recent-file consult--source-project-recent-file
   ;; :preview-key "M-."
   :preview-key '(:debounce 0.4 any))

  ;; Optionally configure the narrowing key.
  ;; Both < and C-+ work reasonably well.
  (setq consult-narrow-key "<") ;; "C-+"

  ;; Optionally make narrowing help available in the minibuffer.
  ;; You may want to use `embark-prefix-help-command' or which-key instead.
  ;; (define-key consult-narrow-map (vconcat consult-narrow-key "?") #'consult-narrow-help)

  ;; By default `consult-project-function' uses `project-root' from project.el.
  ;; Optionally configure a different project root function.
;;;; 1. project.el (the default)
  ;; (setq consult-project-function #'consult--default-project--function)
;;;; 2. vc.el (vc-root-dir)
  ;; (setq consult-project-function (lambda (_) (vc-root-dir)))
;;;; 3. locate-dominating-file
  ;; (setq consult-project-function (lambda (_) (locate-dominating-file "." ".git")))
;;;; 4. projectile.el (projectile-project-root)
  ;; (autoload 'projectile-project-root "projectile")
  ;; (setq consult-project-function (lambda (_) (projectile-project-root)))
;;;; 5. No project support
  ;; (setq consult-project-function nil)
  )

(use-package consult-lsp
  :ensure t
  :config
  (define-key lsp-mode-map [remap xref-find-apropos] #'consult-lsp-symbols))

(use-package embark
  :ensure t

  :bind
  (("C-." . embark-act)         ;; pick some comfortable binding
   ("C-;" . embark-dwim)        ;; good alternative: M-.
   ("C-h B" . embark-bindings)) ;; alternative for `describe-bindings'

  :init

  ;; Optionally replace the key help with a completing-read interface
  (setq prefix-help-command #'embark-prefix-help-command)

  ;; Show the Embark target at point via Eldoc. You may adjust the
  ;; Eldoc strategy, if you want to see the documentation from
  ;; multiple providers. Beware that using this can be a little
  ;; jarring since the message shown in the minibuffer can be more
  ;; than one line, causing the modeline to move up and down:

  ;; (add-hook 'eldoc-documentation-functions #'embark-eldoc-first-target)
  ;; (setq eldoc-documentation-strategy #'eldoc-documentation-compose-eagerly)

  :config

  ;; Hide the mode line of the Embark live/completions buffers
  (add-to-list 'display-buffer-alist
               '("\\`\\*Embark Collect \\(Live\\|Completions\\)\\*"
                 nil
                 (window-parameters (mode-line-format . none)))))

;; Consult users will also want the embark-consult package.
(use-package embark-consult
;;  :straight t
  :ensure t ; only need to install it, embark loads it after consult if found
  :hook
  (embark-collect-mode . consult-preview-at-point-mode))

;; A few more useful configurations...
(use-package emacs
  :ensure nil
  :init
  ;; Add prompt indicator to `completing-read-multiple'.
  ;; We display [CRM<separator>], e.g., [CRM,] if the separator is a comma.
  (defun crm-indicator (args)
    (cons (format "[CRM%s] %s"
                  (replace-regexp-in-string
                   "\\`\\[.*?]\\*\\|\\[.*?]\\*\\'" ""
                   crm-separator)
                  (car args))
          (cdr args)))
  (advice-add #'completing-read-multiple :filter-args #'crm-indicator)

  ;; Do not allow the cursor in the minibuffer prompt
  (setq minibuffer-prompt-properties
        '(read-only t cursor-intangible t face minibuffer-prompt))
  (add-hook 'minibuffer-setup-hook #'cursor-intangible-mode)

  ;; Support opening new minibuffers from inside existing minibuffers.
  (setq enable-recursive-minibuffers t)

  ;; Emacs 28 and newer: Hide commands in M-x which do not work in the current
  ;; mode.  Vertico commands are hidden in normal buffers. This setting is
  ;; useful beyond Vertico.
  (setq read-extended-command-predicate #'command-completion-default-include-p)

  ;; Support prefix completion in orderless
  (setq completion-styles '(basic substring partial-completion flex orderless))

  ;; Use `consult-completion-in-region' if Vertico is enabled.
  ;; Otherwise use the default `completion--in-region' function.
  (setq completion-in-region-function
        (lambda (&rest args)
          (apply (if vertico-mode
                     #'consult-completion-in-region
                   #'completion--in-region)
                 args)))
  (add-hook 'prog-mode-hook #'completion-preview-mode))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Company
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(use-package company
  :ensure t
  :config
  (setq company-idle-delay 0.3)
  (setq company-backends
        '(company-bbdb company-semantic company-cmake company-capf company-files
                       (company-dabbrev-code company-gtags company-etags
                                             company-keywords)
                       company-oddmuse company-dabbrev))
  (global-company-mode 1)

  (global-set-key (kbd "C-<tab>") 'company-complete))

;; ;(require 'cedet)
;; ;(require 'cedet-global)
;; ;(require 'ede)
;; ;; (use-package semantic
;; ;;   :straight t)

(use-package yasnippet                  ; Snippets
  :ensure t
  :config
  (setq
   yas-verbosity 1                      ; No need to be so verbose
   yas-wrap-around-region t)
  (yas-reload-all)
  (yas-global-mode))

(use-package yasnippet-snippets         ; Collection of snippets
  :ensure t
  :config
  (yasnippet-snippets-initialize))

;; (use-package company-lsp
;;   :requires company
;;   :straight t
;;   :commands company-lsp
;;   :config
;;   (push 'company-lsp company-backends))

(use-package hydra
  :ensure t
  )

;; (use-package helm
;;   :straight t
;;   :config
;;   (progn
;;     (global-set-key (kbd "M-x") 'helm-M-x)

;;     (global-set-key (kbd "C-c h") 'helm-command-prefix)
;;     (global-unset-key (kbd "C-x c"))

;;     (define-key helm-map (kbd "<tab>") 'helm-execute-persistent-action) ; rebind tab to run persistent action
;;     (define-key helm-map (kbd "C-i") 'helm-execute-persistent-action) ; make TAB work in terminal
;;     (define-key helm-map (kbd "C-z")  'helm-select-action) ; list actions using C-z

;;     (global-set-key (kbd "M-y") 'helm-show-kill-ring)
;;     (global-set-key (kbd "C-x b") 'helm-mini)
;;     (global-set-key (kbd "C-x C-f") 'helm-find-files)
;;     (setq helm-split-window-in-side-p           t ; open helm buffer inside current window, not occupy whole other window
;; 	  helm-move-to-line-cycle-in-source     t ; move to end or beginning of source when reaching top or bottom of source.
;; 	  helm-ff-search-library-in-sexp        t ; search for library in `require' and `declare-function' sexp.
;; 	  helm-scroll-amount                    8 ; scroll 8 lines other window using M-<next>/M-<prior>
;; 	  helm-ff-file-name-history-use-recentf t
;; 	  helm-echo-input-in-header-line t)

;;     (setq helm-autoresize-max-height 0)
;;     (setq helm-autoresize-min-height 20)
;;     (helm-autoresize-mode 1)

;;     (setq helm-M-x-fuzzy-match t)
;;     (setq helm-buffers-fuzzy-matching t
;; 	  helm-recentf-fuzzy-match    t)
;;     (setq helm-apropos-fuzzy-match t)
;;     (setq helm-semantic-fuzzy-match t
;; 	  helm-imenu-fuzzy-match    t)
;;     (when (executable-find "curl")
;;       (setq helm-google-suggest-use-curl-p t))
;;     (helm-mode 1)))

;; (use-package helm-ls-git
;;   :straight t)

;; (use-package helm-descbinds
;;   :straight t)

;; (use-package helm-lsp
;;   :straight t
;;   :commands helm-lsp-workspace-symbol)

;; (use-package graphviz-dot-mode
;;   :straight t
;;   :config
;;   (setq graphviz-dot-indent-width 2))

;; (use-package company-graphviz-dot)

(use-package transient
  :ensure t)

(use-package magit
  :ensure t
  :bind (("C-x g" . magit-status))
  :config
  ;; Remove sections that make remote network calls when in a TRAMP buffer.
  ;; These sections query the remote git server on every magit-status refresh
  ;; and are a major source of hangs over TRAMP.
  (defun my-magit-remove-remote-sections ()
    (when (and default-directory (file-remote-p default-directory))
      (remove-hook 'magit-status-sections-hook 'magit-insert-unpushed-to-pushremote t)
      (remove-hook 'magit-status-sections-hook 'magit-insert-unpulled-from-pushremote t)
      (remove-hook 'magit-status-sections-hook 'magit-insert-unpulled-from-upstream t)
      (remove-hook 'magit-status-sections-hook 'magit-insert-unpushed-to-upstream-or-recent t)))
  (add-hook 'magit-status-mode-hook #'my-magit-remove-remote-sections)
  (defun my-magit-auto-revert-mode-advice (orig-fun &rest args)
    (unless (and buffer-file-name (file-remote-p buffer-file-name))
      (apply orig-fun args)))
  (advice-add 'magit-turn-on-auto-revert-mode-if-desired
	      :around
	      #'my-magit-auto-revert-mode-advice))
;; (use-package forge
;;   :straight t
;;   :after magit)

(use-package magit-todos
  :ensure t
  :after magit
  :config
  ;; magit-todos scans all tracked files for TODO/FIXME markers.
  ;; Over TRAMP this causes many remote file reads; disable it there.
  (defun my-magit-todos-inhibit-remote (orig-fun &rest args)
    (unless (and default-directory (file-remote-p default-directory))
      (apply orig-fun args)))
  (advice-add 'magit-todos-mode :around #'my-magit-todos-inhibit-remote))

(use-package github-review
  :ensure t
  )

(use-package magit-imerge
;;  :straight t
  :after magit
  :config
  (define-key magit-mode-map (kbd "C-c C-i") 'magit-gitignore)
  (define-key magit-mode-map "i" 'magit-imerge))

;; Overlay-settable path to a project-specific gdb.  Overlays set this.
(defvar my-gud-gdb-executable "gdb"
  "Path to the gdb executable used by `gud'.  Overlays override this.")

(use-package gud
  :ensure nil

  :config
  ;; TODO: Make this parameterizable per-project.
  (let ((gud-gdb-executable my-gud-gdb-executable))
    (setq gud-gud-gdb-command-name (concat "--fullname"))))

(use-package vlf-setup
  :ensure vlf
  )

;; Added for windows support.
(when (eq window-system 'w32)
  (use-package bbdb-mua
    :ensure t
    )
  (use-package bbdb-gnus
    :ensure t
    ))

(use-package cl-lib
  :ensure nil
  )
(use-package smtpmail
  :ensure nil
  )
(use-package icalendar
  :ensure nil
  )

(use-package smtpmail-multi
  :ensure t
  )

;; (use-package doremi
;;   :straight t)
;; (use-package doremi-cmd
;;   :straight t)
;; (use-package doremi-frm
;;   :straight t)

;; (use-package icicle
;;   :straight t)

;; (use-package w3m
;;   :straight t
;;   :config
;;   ;;(require 'w3m)
;;   (autoload 'w3m-browse-url "w3m" "Ask a WWW browser to show a URL." t)
;;   ;; optional keyboard short-cut
;;   (global-set-key "\C-xm" 'browse-url-at-point)
;;   (setq w3m-use-cookies t))

(use-package alert
  :ensure t
  :config
  (cond
   ((memq window-system '(mac ns))
    (setq my-alert-notifier 'osx-notifier))
   (t
    (setq my-alert-notifier 'notifications)))
  (setq alert-default-style my-alert-notifier))

(use-package epg
  :ensure nil
  :config)

(use-package pinentry
  :ensure t
  :defer nil
  :config (pinentry-start))

;; Notify on mail.
;; (use-package gnus-desktop-notify
;;   :straight t)

;; (use-package org-alert
;;   :straight t
;;   :requires (org)
;;   :config
;;   (progn
;;     (org-alert-enable)))

;; (use-package org-super-agenda
;;   :straight t
;;   :requires (org))

;; (use-package ts
;;   :straight (ts :type git :repo "https://github.com/alphapapa/ts.el.git"))

;(use-package org-ql
;  :straight (org-ql :type git :repo "https://github.com/alphapapa/org-ql.git")
;  :requires (org))

;(use-package org-sidebar
;  :straight (org-ql :type git :repo "https://github.com/alphapapa/org-sidebar.git")
;  :requires (org))

;; (use-package calfw-gcal
;;   :straight t
;;   :config
;;   (require 'calfw-gcal))

;; (use-package calfw-org
;;   :straight t
;;   :requires (org)
;;   :config
;;   (require 'calfw-org))

;; (use-package calfw-cal
;;   :straight t
;;   :config
;;   (require 'calfw-cal))

;; (use-package calfw
;;   :straight t
;;   :config
;;   (require 'calfw)
;;   (require 'calfw-org)
;;   (setq cfw:org-overwrite-default-keybinding t)
;;   (require 'calfw-ical)  ;; For Google
;;   (require 'calfw-cal)   ;; For the defun

;;   (diary mycalendar ()
;;     (interactive)
;;     (cfw:open-calendar-buffer
;;      :contents-sources
;;      (list
;;       (cfw:org-create-source "Green")  ;; org schedule
;;       (cfw:cal-create-source "Orange") ;; diary
;;       )))
;;   (setq cfw:org-overwrite-default-keybinding t))

;; (use-package tex
;;   :straight auctex
;;   :defer t
;;   :config
;;   (setq TeX-auto-save t)
;;   (setq TeX-parse-self t))

;; (use-package excorporate
;;   :straight t
;;   :config
;;   (require 'excorporate)
;;   (progn
;;     (setq excorporate-configuration
;; 	  (quote
;; 	   ("user@example.com" . "https://outlook.office365.com/ews/exchange.asmx")))
;;     ;;enable the diary integration (i.e. write exchange calendar to
;;     ;;emacs diary file -> ~/.emacs.d/diary must exist)
;;     (excorporate-diary-enable)
;;     (defun ab/agenda-update-diary ()
;;       "call excorporate to update the diary for today"
;;       (exco-diary-diary-advice (calendar-current-date) (calendar-current-date) #'message "diary updated"))
;;     ;;update the diary every time the org agenda is refreshed
;;     (add-hook 'org-agenda-cleanup-fancy-diary-hook 'ab/agenda-update-diary)))

;; (use-package slime
;;   :straight t
;;   :config
;;   (progn
;;     (setq inferior-lisp-program "/usr/local/bin/sbcl")
;;     (setq slime-contribs '(slime-fancy))))

(use-package cask
  :ensure nil
  )

(use-package cask-mode
  :ensure t
  )

(use-package cask-package-toolset
  :ensure t
  )

(use-package buttercup
  :ensure t
  )

;; MAKES TRAMP HANG
;;
;; (use-package remote-emacsclient
;;   :straight (remote-emacsclient
;;              :type git :repo "https://github.com/habnabit/remote-emacsclient"))

;; Map an LLM provider name to the pass-store account used to look up its
;; API key.  Overlays populate this via `add-to-list'; the entry may be an
;; account string or a function of the provider name returning one.  The
;; default account is used when no provider-specific entry is present.
(defvar my-llm-accounts nil
  "Alist mapping LLM provider name to a pass-store account.")

(defvar my-llm-default-account nil
  "Default pass-store account for LLM API keys when none matches.")

(defun get-llm-api-key (name)
  (let* ((entry (cdr (assoc name my-llm-accounts)))
         (account (cond ((functionp entry) (funcall entry name))
                        (entry entry)
                        (my-llm-default-account my-llm-default-account)
                        (t nil))))
    (when account
      (auth-source-pass-get 'secret (format "%s/%s/apikey" name account)))))

(use-package gptel
  :ensure t
  :bind
  ("C-c g l" . gptel)
  ("C-c g r" . gptel-rewrite)
  ("C-c g s" . my/gptel-model-switch)
  ("C-c g m" . gptel-menu)
  :config
  (setq gptel-api-key (get-llm-api-key "openai.com"))

  (setq my/gptel-gemini-backend
        (gptel-make-gemini
         "Gemini"
         :key (get-llm-api-key "google.com")
         :request-params '(:tools [(:google_search ())]
                                  :generationConfig (:thinkingConfig (:includeThoughts "false")))
         :stream t))

  (setq my/gptel-mistral-backend
        (gptel-make-openai
         "Mistral"
         :host "api.mistral.ai"
         :endpoint "/v1/chat/completions"
         :protocol "https"
         :stream t
         :models '("mistral-small")
         :key (get-llm-api-key "mistral.ai")))

  ;; Additional models offered by `my/gptel-model-switch'.  Overlays add
  ;; their provider's model symbols here.
  (defvar my/gptel-extra-models nil
    "Extra model symbols added to the `my/gptel-model-switch' menu.")

  ;; Alist mapping a model-name prefix to the gptel backend to use.
  ;; Overlays add (PREFIX . BACKEND) entries.
  (defvar my/gptel-backend-alist nil
    "Alist mapping a model-name prefix string to a gptel backend.")

  (defun my/gptel-model-switch ()
    "Switch the LLM provider."
    (interactive)
    (let ((selected (consult--read
                     (append
                      (list 'gemini-2.5-flash-preview-05-20
                            'gemini-2.5-pro-preview-06-05
                            'gpt-4o
                            'mistral-small)
                      my/gptel-extra-models)
                     :prompt "Switch gptel-model: "
                     :require-match t
                     :history 'my/gptel-model-switch)))
      (message "Switched gptel-model to '%s'" (intern selected))
      (setq gptel-model (intern selected))
      (setq gptel-backend
            (or (cdr (seq-find (lambda (pair)
                                 (string-prefix-p (car pair) selected))
                               my/gptel-backend-alist))
                (cond
                 ((string-prefix-p "gemini" selected) my/gptel-gemini-backend)
                 ((string-prefix-p "mistral" selected) my/gptel-mistral-backend)
                 (t gptel--openai))))))

  ;; (setq gptel-model 'gemini-2.5-flash-preview-04-17)
  ;; (setq gptel-backend my/gptel-gemini-backend)

  (setq gptel-default-mode 'org-mode)
  (setq gptel-prompt-prefix-alist '((org-mode . "* ")))

  (setq gptel-log-level 'info))

(use-package aidermacs
  :ensure t
  :bind (("C-c e" . aidermacs-transient-menu))
  :config
  (setenv "OPENAI_API_KEY" (get-llm-api-key "openai.com"))
  (setenv "MISTRAL_API_KEY" (get-llm-api-key "mistral.ai"))
  (setenv "GEMINI_API_KEY" (get-llm-api-key "google.com"))
  ;; The default aider models (and any provider-specific API-key env vars)
  ;; are set by a private overlay.
  (setq aidermacs-backend 'vterm)
  (setq aidermacs-vterm-multiline-newline-key "C-<return>")
  (setq aidermacs-watch-files t)
  ;; Always add these files as read-only to all Aidermacs sessions
  ;; For files that exists outside the project directory
  (setq aidermacs-global-read-only-files '("~/.aider/AI_RULES.md"))
  ;; For files that exists within the project directory
  (setq aidermacs-project-read-only-files '("CONVENTIONS.md" "README.md"))
  ;; Kill the Aider buffer when exiting the session
  (setq aidermacs-exit-kills-buffer t)
  (setq aidermacs-default-chat-mode 'architect))

;; claude-code.el
(use-package eat
  :ensure t)

(use-package inheritenv
  :ensure (:fetcher github :repo "purcell/inheritenv" :branch "main"))

(use-package monet
  :ensure (:fetcher github :repo "stevemolitor/monet" :branch "main"))

(use-package claude-code
  :ensure (:fetcher github :repo "stevemolitor/claude-code.el" :branch "main")
  :bind-keymap
  ("C-c C" . claude-code-command-map) ;; or your preferred key
  ;; Optionally define a repeat map so that "M" will cycle thru Claude auto-accept/plan/confirm modes after invoking claude-code-cycle-mode / C-c M.
  :bind
  (:repeat-map my-claude-code-map ("M" . claude-code-cycle-mode))
  :config
  ;; optional IDE integration with Monet
  ;;(add-hook 'claude-code-process-environment-functions #'monet-start-server-function)
  ;;(monet-mode 1)
  (setq claude-code-terminal-backend 'claude)
  (vterm-code-mode))
(use-package project
  ;; project.el is built-in, so tell elpaca to ignore it
  :elpaca nil
  ;; Optional: Add any initial settings
  :init
  (setq project-vc-system 'git) ;; Use git for version control detection
  ;; Optional: Define custom keybindings
  :config
  ;;(define-key project-prefix-map (kbd "C-f") 'project-find-file)
  ;;(define-key project-prefix-map (kbd "C-d") 'project-find-dir)
  ;;(define-key project-prefix-map (kbd "C-k") 'project-kill-buffers)
  ;; project.el binds to C-x p by default
  ;; Use the built-in commands like C-x p f to find a file in the project
  (setq project-vc-extra-root-markers '("Cargo.toml"
                                        "package.json"
                                        "pyproject.toml"))
  (defun alc-project-try-vc-subproject (orig-fun &rest args)
    "Advice for `project-try-vc'.

When using `project-vc-extra-root-markers' to teach project.el
about subprojects within a monorepo, `project-try-vc'
successfully finds the subject's root but fails to detect the
backend. But by calling `vc-responsible-backend' on the found
root, we can fill in the blanks.

As a result, commands like `project-find-file' now respect the
parent repo's .gitignore file even when being run from within a
subproject."
    (let* ((res (apply orig-fun args))
           (dir (nth 2 res))
           (backend (or (nth 1 res)
                        (ignore-errors (vc-responsible-backend dir)))))
      (if dir
          `(vc ,backend ,dir))))

  (advice-add 'project-try-vc :around #'alc-project-try-vc-subproject)
  )

(use-package quite
  :ensure (:fetcher github :branch "dev" :repo "greened/quite" :try-local t)
  :config
  (progn
    (defun generate-build-defun (name
                                 command
                                 git-project-name
                                 &optional
                                 prefix
                                 postfix)
      "Given a NAME and a git-project COMMAND, return a function
      that invokes git-project with that command when invoked
      with project descriptor components and the dispatch tag."
      (let ((loc-name name)
            (loc-command command)
            (loc-command-template (format
                                   "%s git %s %%s %%s %s"
                                   (or prefix "")
                                   git-project-name
                                   (or postfix ""))))
        (lambda (host-user-method root subdir buffer tag)
          (let ((actual-tag tag))
            (compile (format loc-command-template loc-command actual-tag))))))

    ;;     (defun zip (list-a list-b)
    ;;       "Generate a zipped list consisting of elements of LIST-A
    ;; and LIST-B.  Only generate elements up to the end of one of the
    ;; lists.  Elements in the longer list are ignored."
    ;;       (cond
    ;;        ((or (null list-a) (null list-b)) ())
    ;;        (t (let ((item-a (car list-a))
    ;;                 (item-b (car list-b)))
    ;;             (let* ((list-item (list item-a item-b))
    ;;                    (zip-item (zip (cdr list-a) (cdr list-b))))
    ;;               (cons list-item zip-item))))))

    (defun broadcast-function-to-tag-function-alist (command-func flavor-list)
      (message "flavor-list: %s" flavor-list)
      (mapcar (lambda (flavor)
                `(,flavor ,command-func))
              flavor-list))

    (defun generate-buffer-name-defun (project-name name)
      "Given a NAME component of the eventual buffer name, return
      a function that generates a buffer name from project
      descriptor components and the dispatch tag."
      (let ((loc-project-name project-name)
            (loc-name name))
        (lambda (host root subdir buffer tag)
          (format "*%s-%s-%s-%s-%s*"
                  loc-project-name
                  loc-name
                  subdir
                  tag
                  (nth 0 (split-string host "\\."))))))

    ;; (defun bind-project-keys
    ;;     (project-name project-descriptor command-list prefix-key)
    ;;   (dolist (item command-list)
    ;;     (let* ((name (nth 0 item))
    ;;            (command (nth 1 item))
    ;;            (flavor-list-list (nth 2 item))
    ;;            (key-list (nth 3 item))
    ;;            (build-func (generate-build-defun name command))
    ;;            (buffer-name-func (generate-buffer-name-defun project-name name))
    ;;            ;; Create a list of (key flavor-list) pairs.
    ;;            (key-flavor-list-list (zip key-list flavor-list-list)))
    ;;       (dolist (key-flavor-list key-flavor-list-list)
    ;;         (let* ((key (nth 0 key-flavor-list))
    ;;                (flavor-list (nth 1 key-flavor-list))
    ;;                (tag-function-alist
    ;;                 (broadcast-function-to-tag-function-alist
    ;;                  build-func flavor-list)))
    ;;           ;; TODO: Support proper keymaps.
    ;;           (global-set-key (kbd (concat "C-c " prefix-key key))
    ;;                           (quite-generate-buffer-dispatcher
    ;;                            project-descriptor
    ;;                            buffer-name-func
    ;;                            tag-function-alist)))))))

    ;; Hydra support

    (defun shorten-flavor (list)
      (mapcar
       (lambda (item)
         (replace-regexp-in-string
          "local" "lo"
          (replace-regexp-in-string
           "cluster" "cl"
           (replace-regexp-in-string
            "dev" "d"
            (replace-regexp-in-string
             "rel" "r"
             (replace-regexp-in-string
              "dbg" "d"
              (replace-regexp-in-string
               "up" "u"
               (replace-regexp-in-string
                "all-" ""
                (replace-regexp-in-string "all-llvm-build" "le" item))))))))) list))

    ;; (defun generate-hydra-heads (project-name command-list)
    ;;   (let ((result '()))
    ;;     (dolist (item command-list result)
    ;;       (let* ((name (nth 0 item))
    ;;              (command (nth 1 item))
    ;;              (flavor-list-list (nth 2 item))
    ;;              (key-list (nth 3 item))
    ;;              ;; Create a list of (key flavor-list) pairs.
    ;;              (key-flavor-list-list (zip key-list flavor-list-list)))
    ;;         (dolist (key-flavor-list key-flavor-list-list)
    ;;           (let* ((key (nth 0 key-flavor-list))
    ;;                  (flavor-list (nth 1 key-flavor-list))
    ;;                  (description (format "%s" (mapconcat 'identity (shorten-flavor flavor-list) " ")))
    ;;                  (column (format "%s %s" project-name name)))
    ;;             ;; Hydrra head: (KEY FUNC DESC :column COLUMN)
    ;;             (setq result (append result
    ;;                                  `((,key
    ;;                                     ,(key-binding
    ;;                                       (kbd (concat "C-c " key)))
    ;;                                     ,description
    ;;                                     :column
    ;;                                     ,column))))))))))

    ;; Project composition
    (defun compose-project
        (git-project-name
         project-name
         project-descriptor
         prefix-key
         target
         commands-plist-list
         prefix-plist-list
         transform-plist-list
         &optional
         command-prefix
         command-postfix)
      (let ((result '()))
        (dolist (command-plist commands-plist-list result)
          (let* ((command-name (plist-get command-plist :name))
                 (command (plist-get command-plist :command))
                 (command-key (plist-get command-plist :key))
                 (build-func
                  (generate-build-defun command-name
                                        command git-project-name
                                        command-prefix
                                        command-postfix))
                 (buffer-name-func (generate-buffer-name-defun project-name
                                                               command-name)))
            (dolist (transform-plist transform-plist-list)
              (let ((transform-name (plist-get transform-plist :name))
                    (transform-func (plist-get transform-plist :func))
                    (flavor-list '()))
                (dolist (prefix-plist prefix-plist-list)
                  (let* ((prefix-name (plist-get prefix-plist :name))
                         (prefix-prefix (plist-get prefix-plist :prefix))
                         (flavor-name (format "%s-%s-%s"
                                              target prefix-name transform-name)))
                    (setq flavor-list (append flavor-list (list flavor-name)))))
                (let ((tag-function-alist
                       (broadcast-function-to-tag-function-alist build-func
                                                                 flavor-list))
                      (description (format "%s"
                                           (mapconcat 'identity
                                                      (shorten-flavor flavor-list)
                                                      " ")))
                      (column (format "%s %s" project-name command-name)))
                  ;; TODO: Support proper keymaps.
                  (global-set-key (kbd (concat "C-c "
                                               prefix-key
                                               (funcall transform-func
                                                        command-key)))
                                  (quite-generate-buffer-dispatcher
                                   project-descriptor
                                   buffer-name-func
                                   tag-function-alist))
                  ;; Hydra head: (KEY FUNC DESC :column COLUMN)
                  (setq result (append result
                                       `((,(funcall transform-func command-key)
                                          ,(key-binding
                                            (kbd (concat "C-c "
                                                         prefix-key
                                                         (funcall transform-func
                                                                  command-key))))
                                          ,description
                                          :column
                                          ,column)))))))))))

    ;; Common keys.
    (setq configure-key "f")
    (setq build-key "b")
    (setq install-key "i")
    (setq check-key "k")
    (setq benchmark-key "m")
    (setq bic-key "q")

    ;; Build configuration.  There are a number of different build targets and
    ;; various flavors of each target build.  For each kind of build we want to
    ;; allow two kinds of builds: a release build and a debug build.
    ;;
    ;; We'll bind keys to each build kind and use a prefix argument to determine
    ;; whether we do a release (no prefix) or debug (one prefix) build.

    (setq command-plist-list
          `((:name "configure" :command "configure" :key ,configure-key)
            (:name "build" :command "build" :key ,build-key)
            (:name "check" :command "check" :key ,check-key)
            (:name "install" :command "install" :key ,install-key)
            (:name "benchmark" :command "benchmark" :key ,benchmark-key)
            (:name "bic" :command "bic" :key ,bic-key)))

    ;; Shared
    (setq git-be-name "be")

    (setq prefix-plist-list '((:name "devrel" :prefix 0)
                              (:name "devdbg" :prefix 1)))

    (setq transform-plist-list '((:name "local" :func identity)
                                 (:name "cluster" :func upcase)))

    ;; Project-specific build hydras (employer and personal source trees)
    ;; live in overlays; they use the generic `compose-project' machinery
    ;; defined above.
    ))

(elpaca-wait)
