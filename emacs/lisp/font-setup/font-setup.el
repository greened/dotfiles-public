;;; font-setup.el --- One font set, Nerd icons pinned -*- lexical-binding: t -*-

;; Copyright (C) 2026 David Greene

;; Author: David Greene (with Claude Code)
;; Maintainer: David Greene
;; Version: 0.1.0
;; Keywords: faces, terminals
;; URL: https://github.com/USER/font-setup
;; Package-Requires: ((emacs "27.1"))

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published
;; by the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.
;;
;; You should have received a copy of the GNU Affero General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Use the same fonts on macOS and Linux, so Powerline arrows and Nerd Font
;; icons line up in terminals inside Emacs. The default face gets
;; `font-setup-default-family'. The Nerd Font code points in
;; `font-setup-symbols-ranges' go to `font-setup-symbols-family' in the
;; default fontset, so frames that a daemon makes later get them too.
;;
;;   (require 'font-setup)
;;   (font-setup-enable)
;;
;; When the symbols font is missing on Debian forky or sid, a warning names
;; the apt package. Elsewhere it asks once whether to download the font from
;; the Nerd Fonts release, checks its sha256 and installs the one file. A
;; "no" is recorded in `font-setup-declined-file'. Delete that file to be
;; asked again, or run `font-setup-install-symbols' to install at any time.

;;; Code:

(require 'seq)
(require 'subr-x)

(defgroup font-setup nil
  "One font set on macOS and Linux, with Nerd Font icons pinned."
  :group 'faces
  :prefix "font-setup-")

(defcustom font-setup-default-family "JetBrains Mono"
  "Font family for the default face."
  :type 'string)

(defcustom font-setup-default-height nil
  "Height of the default face in 1/10 pt, or nil to keep the current one."
  :type '(choice (const :tag "Keep the current height" nil) integer))

(defcustom font-setup-symbols-family "Symbols Nerd Font Mono"
  "Font family for the code points in `font-setup-symbols-ranges'."
  :type 'string)

(defcustom font-setup-symbols-ranges
  '((#xE000 . #xF8FF)                   ; the Private Use Area
    (#xF0001 . #xF1AF0))                ; Nerd Fonts v3 Material Design icons
  "Code point ranges given to `font-setup-symbols-family'.
Each entry is a cons (FROM . TO), both inclusive."
  :type '(repeat (cons integer integer)))

(defcustom font-setup-apt-codenames '("forky" "sid")
  "Debian codenames that package the symbols font.
On these the missing font is an apt hint instead of a download offer."
  :type '(repeat string))

(defcustom font-setup-default-apt-package "fonts-jetbrains-mono"
  "Debian package that provides `font-setup-default-family'."
  :type 'string)

(defcustom font-setup-symbols-apt-package "fonts-nerd-symbols"
  "Debian package that provides `font-setup-symbols-family'."
  :type 'string)

(defcustom font-setup-nerd-fonts-version "3.5.1"
  "Nerd Fonts release to download the symbols font from."
  :type 'string)

(defcustom font-setup-download-url
  "https://github.com/ryanoasis/nerd-fonts/releases/download/v%s/NerdFontsSymbolsOnly.tar.xz"
  "URL of the symbols archive.
A %s in it is replaced by `font-setup-nerd-fonts-version'. Only an https
URL is used."
  :type 'string)

(defcustom font-setup-download-sha256
  "01172f37db8543edb102e5cb5c64101c9f4686630804d49b419aa07b23a69996"
  "Expected sha256 of the archive at `font-setup-download-url'.
Change it together with `font-setup-nerd-fonts-version'. An archive with
any other hash is refused."
  :type 'string)

(defcustom font-setup-download-member "SymbolsNerdFontMono-Regular.ttf"
  "The one file installed from the archive."
  :type 'string)

(defcustom font-setup-download-max-time 300
  "Seconds before the download is given up."
  :type 'integer)

(defcustom font-setup-install-directory nil
  "Directory the font is installed in.
nil means ~/Library/Fonts on macOS and ~/.local/share/fonts elsewhere."
  :type '(choice (const :tag "Platform default" nil) directory))

(defcustom font-setup-declined-file
  (locate-user-emacs-file "font-setup-declined")
  "File that records a \"no\" to the download offer.
While it exists the offer is not made. Delete it to be asked again."
  :type 'file)

(defconst font-setup--max-download-bytes (* 64 1024 1024)
  "Largest archive curl accepts.")

(defvar font-setup-os-release-file "/etc/os-release"
  "File the Linux distribution and codename are read from.")

(defvar font-setup--checked nil
  "Non-nil once a graphical frame ran the check in this session.")

;;; Decisions

(defun font-setup--parse-os-release (text)
  "Return the KEY=VALUE lines of TEXT, an os-release file, as an alist."
  (let (out)
    (dolist (line (split-string text "\n" t))
      (when (string-match "\\`\\([A-Z_]+\\)=\\(.*\\)\\'" line)
        (push (cons (match-string 1 line)
                    (string-trim (match-string 2 line) "[\"']" "[\"']"))
              out)))
    (nreverse out)))

(defun font-setup--os-release ()
  "Return `font-setup-os-release-file' parsed, or nil if it is unreadable."
  (when (file-readable-p font-setup-os-release-file)
    (with-temp-buffer
      ;; Bounded, since the file is outside our control.
      (insert-file-contents font-setup-os-release-file nil 0 65536)
      (font-setup--parse-os-release (buffer-string)))))

(defun font-setup--debian-p (os)
  "Non-nil if OS, a parsed os-release, is Debian."
  (equal (cdr (assoc "ID" os)) "debian"))

(defun font-setup--codename (os)
  "Return the codename in OS, a parsed os-release, or nil.
Some sid images leave VERSION_CODENAME empty and name sid only in
PRETTY_NAME."
  (let ((code (cdr (assoc "VERSION_CODENAME" os))))
    (cond ((and code (not (string-empty-p code))) code)
          ((member "sid" (split-string
                          (or (cdr (assoc "PRETTY_NAME" os)) "")
                          "[^[:alnum:]]+" t))
           "sid"))))

(defun font-setup--apt-p (system os)
  "Non-nil if SYSTEM and OS name a Debian that packages the symbols font."
  (and (eq system 'gnu/linux)
       (font-setup--debian-p os)
       (member (font-setup--codename os) font-setup-apt-codenames)
       t))

(defun font-setup-symbols-action (present system os declined)
  "Return what to do about the symbols font.
PRESENT is non-nil if the font was found. SYSTEM is a `system-type'. OS
is a parsed os-release. DECLINED is non-nil if the user said no before.
The result is `none', `apt-hint', `declined' or `offer'."
  (cond (present 'none)
        ((font-setup--apt-p system os) 'apt-hint)
        ((not (memq system '(gnu/linux darwin))) 'none)
        (declined 'declined)
        (t 'offer)))

(defun font-setup-default-action (present system os)
  "Return what to do about the default family.
PRESENT, SYSTEM and OS are as for `font-setup-symbols-action'. The
result is `apt-hint' for a missing font on Debian, otherwise `none'."
  (if (and (not present) (eq system 'gnu/linux) (font-setup--debian-p os))
      'apt-hint
    'none))

;;; Applying the fonts

(defun font-setup-apply (&optional frame)
  "Set the default face and pin the symbols ranges on FRAME.
Only a font that `find-font' finds is used. `font-setup-default-height'
is applied either way. Return a cons (DEFAULT-FOUND . SYMBOLS-FOUND)."
  (let ((default (find-font (font-spec :family font-setup-default-family)
                            frame))
        (symbols (find-font (font-spec :family font-setup-symbols-family)
                            frame)))
    (let ((attrs (append (and default
                              (list :family font-setup-default-family))
                         (and font-setup-default-height
                              (list :height font-setup-default-height)))))
      (when attrs
        (apply #'set-face-attribute 'default nil attrs)))
    (when symbols
      (dolist (range font-setup-symbols-ranges)
        (set-fontset-font t range
                          (font-spec :family font-setup-symbols-family))))
    (cons (and default t) (and symbols t))))

(defun font-setup--on-frame (frame)
  "Apply the fonts once FRAME is graphical, and act on any that are missing.
Runs once per session."
  (when (and (not noninteractive)
             (not font-setup--checked)
             (display-graphic-p frame))
    (setq font-setup--checked t)
    (remove-hook 'after-make-frame-functions #'font-setup--on-frame)
    (let* ((found (font-setup-apply frame))
           (os (and (eq system-type 'gnu/linux) (font-setup--os-release)))
           (symbols (font-setup-symbols-action
                     (cdr found) system-type os
                     (file-exists-p font-setup-declined-file)))
           (hints (delq nil
                        (list (and (eq (font-setup-default-action
                                        (car found) system-type os)
                                       'apt-hint)
                                   font-setup-default-apt-package)
                              (and (eq symbols 'apt-hint)
                                   font-setup-symbols-apt-package)))))
      (when hints
        (display-warning
         'font-setup
         (format "Missing fonts. Install them with: sudo apt install %s"
                 (string-join hints " "))))
      (when (eq symbols 'offer)
        ;; Wait for idle, so the question does not land mid-startup.
        (run-with-idle-timer 1 nil #'font-setup--offer frame)))))

;;;###autoload
(defun font-setup-enable ()
  "Apply the fonts now if the frame is graphical, else on the first one.
Does nothing in batch mode."
  (unless noninteractive
    (if (display-graphic-p)
        (font-setup--on-frame (selected-frame))
      (add-hook 'after-make-frame-functions #'font-setup--on-frame))))

;;; The download offer

(defun font-setup--record-decline ()
  "Record a \"no\" in `font-setup-declined-file'."
  (make-directory (file-name-directory font-setup-declined-file) t)
  (write-region (format "Declined the %s download. Delete this file to be \
asked again.\n" font-setup-symbols-family)
                nil font-setup-declined-file nil 'silent)
  (message "font-setup: not asking again; delete %s to undo"
           font-setup-declined-file))

(defun font-setup--offer-on-frame (frame)
  "Offer the download on FRAME, the next graphical frame."
  (when (display-graphic-p frame)
    (remove-hook 'after-make-frame-functions #'font-setup--offer-on-frame)
    (run-with-idle-timer 1 nil #'font-setup--offer frame)))

(defun font-setup--offer (frame)
  "Ask on FRAME whether to download the symbols font, and act on the answer.
If FRAME was closed or is not graphical, wait for the next graphical frame.
Ask nothing if the font or a decline appeared while the offer waited."
  ;; Another Emacs may have installed the font or recorded a no meanwhile.
  (unless (or noninteractive (file-exists-p font-setup-declined-file))
    (if (not (and (frame-live-p frame) (display-graphic-p frame)))
        (add-hook 'after-make-frame-functions #'font-setup--offer-on-frame)
      (unless (find-font (font-spec :family font-setup-symbols-family) frame)
        ;; yes-or-no-p, so a stray key cannot record a lasting no.
        (if (with-selected-frame frame
              (yes-or-no-p
               (format "%s is missing. Download it from Nerd Fonts %s? "
                       font-setup-symbols-family
                       font-setup-nerd-fonts-version)))
            (font-setup-install-symbols)
          (font-setup--record-decline))))))

(defun font-setup--install-directory ()
  "Return the directory the font is installed in."
  (expand-file-name (or font-setup-install-directory
                        (if (eq system-type 'darwin)
                            "~/Library/Fonts"
                          "~/.local/share/fonts"))))

(defun font-setup--cleanup (tmp)
  "Delete TMP, the scratch directory, if there is one."
  (when (and tmp (file-directory-p tmp))
    (delete-directory tmp t)))

(defun font-setup--step (tmp then)
  "Return THEN wrapped so that an error in it is reported and TMP deleted."
  (lambda (out)
    (condition-case err
        (funcall then out)
      (error
       (message "font-setup: install failed: %s" (error-message-string err))
       (font-setup--cleanup tmp)))))

(defun font-setup--run (name command tmp then)
  "Run COMMAND, a list, asynchronously and call THEN with its output.
NAME labels the process and any failure message. On a failure, TMP is
deleted and THEN is not called."
  (let ((buf (generate-new-buffer (format " *font-setup %s*" name))))
    (condition-case err
        (make-process
         :name (concat "font-setup-" name)
         :buffer buf
         :command command
         :connection-type 'pipe
         :noquery t
         :sentinel
         (lambda (proc _event)
           (unless (process-live-p proc)
             (let ((ok (and (eq (process-status proc) 'exit)
                            (zerop (process-exit-status proc))))
                   (out (with-current-buffer buf (buffer-string))))
               (kill-buffer buf)
               (if ok
                   (funcall then out)
                 (message "font-setup: %s failed: %s" name (string-trim out))
                 (font-setup--cleanup tmp))))))
      (error
       (kill-buffer buf)
       (message "font-setup: cannot run %s: %s" name
                (error-message-string err))
       (font-setup--cleanup tmp)))))

(defun font-setup--sha256-ok-p (file expected)
  "Non-nil if the sha256 of FILE is EXPECTED."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (string= (secure-hash 'sha256 (current-buffer)) (downcase expected))))

(defun font-setup--pick-member (listing member)
  "Return the entry of LISTING, `tar -t' output, whose file name is MEMBER.
An absolute entry or one with a \"..\" component is never picked."
  (seq-find (lambda (entry)
              (and (equal (file-name-nondirectory entry) member)
                   (not (file-name-absolute-p entry))
                   (not (member ".." (split-string entry "/")))))
            (split-string listing "[\r\n]+" t)))

;;;###autoload
(defun font-setup-install-symbols ()
  "Download and install the symbols font, in the background.
The archive must match `font-setup-download-sha256'. Only
`font-setup-download-member' is installed."
  (interactive)
  (let ((url (format font-setup-download-url font-setup-nerd-fonts-version)))
    (if (not (string-prefix-p "https://" url))
        (message "font-setup: refusing a URL that is not https: %s" url)
      (let* ((tmp (make-temp-file "font-setup-" t))
             (archive (expand-file-name "symbols.tar.xz" tmp)))
        (message "font-setup: downloading %s in the background" url)
        (font-setup--run
         "curl"
         ;; -q first, so a ~/.curlrc cannot change the request.
         (list "curl" "-q" "--fail" "--silent" "--show-error" "--location"
               "--proto" "=https" "--proto-redir" "=https"
               "--max-time" (number-to-string font-setup-download-max-time)
               "--max-filesize"
               (number-to-string font-setup--max-download-bytes)
               "--output" archive url)
         tmp
         (font-setup--step
          tmp (lambda (_out) (font-setup--check-archive archive tmp))))))))

(defun font-setup--check-archive (archive tmp)
  "Verify ARCHIVE in TMP, then list it. Refuse it on a hash mismatch."
  (if (not (font-setup--sha256-ok-p archive font-setup-download-sha256))
      (progn
        (message "font-setup: refused the download: its sha256 is not %s"
                 font-setup-download-sha256)
        (font-setup--cleanup tmp))
    (font-setup--run
     "tar-list" (list "tar" "-tf" archive) tmp
     (font-setup--step
      tmp
      (lambda (listing)
        (let ((entry (font-setup--pick-member listing
                                              font-setup-download-member)))
          (if (not entry)
              (progn
                (message "font-setup: %s is not in the archive"
                         font-setup-download-member)
                (font-setup--cleanup tmp))
            (font-setup--run
             "tar-extract" (list "tar" "-xf" archive "-C" tmp "--" entry) tmp
             (font-setup--step
              tmp
              (lambda (_out)
                (font-setup--install-file
                 (expand-file-name entry tmp) tmp)))))))))))

(defun font-setup--install-file (src tmp)
  "Copy SRC, the extracted font, into place and finish. Delete TMP."
  (if (or (not (file-regular-p src)) (file-symlink-p src))
      (progn
        (message "font-setup: %s is not a regular file" src)
        (font-setup--cleanup tmp))
    (let* ((dir (font-setup--install-directory))
           (dest (expand-file-name font-setup-download-member dir)))
      (make-directory dir t)
      ;; A rename replaces a symlink at DEST, where a copy would follow it.
      (let ((part (make-temp-file (expand-file-name ".font-setup-" dir))))
        (unwind-protect
            (progn
              (copy-file src part t)
              (set-file-modes part #o644)
              (rename-file part dest t))
          (when (file-exists-p part)
            (delete-file part))))
      (font-setup--cleanup tmp)
      (if (eq system-type 'darwin)
          (font-setup--finish dest)
        (font-setup--run "fc-cache" (list "fc-cache" "-f" dir) nil
                         (font-setup--step
                          nil (lambda (_out) (font-setup--finish dest))))))))

(defun font-setup--finish (dest)
  "Apply the fonts again after DEST was installed, and say so."
  (clear-font-cache)
  (let ((frame (selected-frame)))
    (when (display-graphic-p frame)
      (font-setup-apply frame)))
  (message "font-setup: installed %s%s" dest
           (if (eq system-type 'darwin)
               ". Restart Emacs if the icons do not show."
             "")))

(provide 'font-setup)
;;; font-setup.el ends here
