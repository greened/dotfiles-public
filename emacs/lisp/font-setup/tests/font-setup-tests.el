;;; font-setup-tests.el --- Tests for font-setup -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; What is tested is the decision: which action a platform gets for a missing
;; font, whether an archive is refused and which entry is installed. The
;; effects are not performed. `font-setup--run' is stubbed in every install
;; case, so no test starts curl, tar or fc-cache, and nothing is downloaded.
;; The stub plays each step by writing the files that step would leave.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'font-setup)

(defvar fst-faces)
(defvar fst-pins)
(defvar fst-warnings)
(defvar fst-timers)
(defvar fst-ran)
(defvar fst-dest)
(defvar fst-tmp)
(defvar fst-graphic)
(defvar fst-installed)
(defvar fst-prompt-frame)
(defvar fst-messages)
(defvar fst-extract-as)
(defvar fst-symbols-found)

(defun fst-os (text)
  "Parse TEXT as an os-release file."
  (font-setup--parse-os-release text))

(defconst fst-forky (fst-os "ID=debian\nVERSION_CODENAME=forky\n"))
(defconst fst-sid (fst-os "ID=debian\nVERSION_CODENAME=sid\n"))
(defconst fst-sid-pretty-only
  (fst-os "PRETTY_NAME=\"Debian GNU/Linux forky/sid\"\nID=debian\n"))
(defconst fst-trixie (fst-os "ID=debian\nVERSION_CODENAME=trixie\n"))
(defconst fst-bookworm (fst-os "ID=debian\nVERSION_CODENAME=bookworm\n"))
(defconst fst-fedora (fst-os "ID=fedora\nVERSION_CODENAME=\"\"\n"))

;;; The decisions

(ert-deftest fst-parses-quoted-values ()
  "Quotes around a value are not part of it."
  (should (equal (cdr (assoc "PRETTY_NAME" fst-sid-pretty-only))
                 "Debian GNU/Linux forky/sid"))
  (should (equal (cdr (assoc "ID" fst-forky)) "debian")))

(defconst fst-os-names
  `((,fst-forky . "forky") (,fst-sid . "sid")
    (,fst-sid-pretty-only . "sid in PRETTY_NAME") (,fst-trixie . "trixie")
    (,fst-bookworm . "bookworm") (,fst-fedora . "fedora") (nil . "no file"))
  "A readable name for each os-release fixture.")

(defmacro fst-each-os (var oses &rest body)
  "Run BODY with VAR bound to each of OSES, naming the OS on a failure."
  (declare (indent 2))
  `(dolist (,var ,oses)
     (ert-info ((cdr (assoc ,var fst-os-names)) :prefix "os: ")
       ,@body)))

(ert-deftest fst-symbols-missing-forky-and-sid-get-an-apt-hint ()
  "The releases that package the font are told to install it."
  (fst-each-os os (list fst-forky fst-sid fst-sid-pretty-only)
    (should (eq (font-setup-symbols-action nil 'gnu/linux os nil) 'apt-hint))))

(ert-deftest fst-symbols-missing-elsewhere-gets-an-offer ()
  "Debian trixie and bookworm, another Linux and macOS get the offer."
  (fst-each-os os (list fst-trixie fst-bookworm fst-fedora nil)
    (should (eq (font-setup-symbols-action nil 'gnu/linux os nil) 'offer)))
  (should (eq (font-setup-symbols-action nil 'darwin nil nil) 'offer)))

(ert-deftest fst-symbols-missing-on-windows-needs-nothing ()
  "Only macOS and Linux are offered anything."
  (should (eq (font-setup-symbols-action nil 'windows-nt nil nil) 'none)))

(ert-deftest fst-symbols-present-needs-nothing ()
  "A font that is found needs no action anywhere."
  (fst-each-os os (list fst-forky fst-sid fst-trixie fst-bookworm fst-fedora)
    (should (eq (font-setup-symbols-action t 'gnu/linux os nil) 'none)))
  (should (eq (font-setup-symbols-action t 'darwin nil nil) 'none)))

(ert-deftest fst-a-decline-stops-the-offer ()
  "A recorded no stops the offer, but an apt hint still shows."
  (fst-each-os os (list fst-trixie fst-bookworm fst-fedora)
    (should (eq (font-setup-symbols-action nil 'gnu/linux os t) 'declined)))
  (should (eq (font-setup-symbols-action nil 'darwin nil t) 'declined))
  (should (eq (font-setup-symbols-action nil 'gnu/linux fst-forky t)
              'apt-hint)))

(ert-deftest fst-default-missing-hints-only-on-debian ()
  "JetBrains Mono is packaged in every Debian release, and nowhere else."
  (fst-each-os os (list fst-forky fst-sid fst-trixie fst-bookworm)
    (should (eq (font-setup-default-action nil 'gnu/linux os) 'apt-hint))
    (should (eq (font-setup-default-action t 'gnu/linux os) 'none)))
  (should (eq (font-setup-default-action nil 'gnu/linux fst-fedora) 'none))
  (should (eq (font-setup-default-action nil 'darwin nil) 'none)))

;;; Applying the fonts

(defun fst-family (spec)
  "Return the family of font SPEC as a string, not a symbol."
  (format "%s" (font-get spec :family)))

(defmacro fst-with-fonts (found &rest body)
  "Run BODY with `find-font' finding the families in FOUND.
`fst-faces' and `fst-pins' collect the calls that set fonts."
  (declare (indent 1))
  `(let ((fst-faces nil) (fst-pins nil))
     (cl-letf (((symbol-function 'find-font)
                (lambda (spec &optional _frame)
                  (and (member (fst-family spec) ,found) 'entity)))
               ((symbol-function 'set-face-attribute)
                (lambda (&rest args) (push args fst-faces)))
               ((symbol-function 'set-fontset-font)
                (lambda (fontset range spec &rest _)
                  (push (list fontset range (fst-family spec))
                        fst-pins))))
       ,@body)))

(ert-deftest fst-apply-pins-every-range-in-the-default-fontset ()
  "Each range goes to the symbols family in fontset t."
  (fst-with-fonts (list "JetBrains Mono" "Symbols Nerd Font Mono")
    (let ((font-setup-default-height 140))
      (should (equal (font-setup-apply) '(t . t))))
    (should (equal (reverse fst-pins)
                   '((t (#xE000 . #xF8FF) "Symbols Nerd Font Mono")
                     (t (#xF0001 . #xF1AF0) "Symbols Nerd Font Mono"))))
    (should (equal fst-faces
                   '((default nil :family "JetBrains Mono" :height 140))))))

(ert-deftest fst-apply-keeps-the-height-when-unset ()
  "A nil height leaves the current one."
  (fst-with-fonts (list "JetBrains Mono")
    (let ((font-setup-default-height nil))
      (font-setup-apply))
    (should (equal fst-faces '((default nil :family "JetBrains Mono"))))))

(ert-deftest fst-apply-sets-nothing-for-a-missing-font ()
  "A font `find-font' cannot find is never pinned."
  (fst-with-fonts nil
    (let ((font-setup-default-height nil))
      (should (equal (font-setup-apply) '(nil . nil))))
    (should-not fst-pins)
    (should-not fst-faces)))

(ert-deftest fst-apply-sets-the-height-without-the-family ()
  "A configured height still applies when the family is missing."
  (fst-with-fonts nil
    (let ((font-setup-default-height 120))
      (font-setup-apply))
    (should (equal fst-faces '((default nil :height 120))))))

;;; The frame hook

(defmacro fst-with-frame (os-text found &rest body)
  "Run BODY as a graphical session on Linux with OS-TEXT as os-release.
FOUND lists the families `find-font' finds. `fst-warnings' and
`fst-timers' collect what the hook asked for. Each timer is recorded as
\(FUNCTION . ARGS). `fst-graphic' says whether a frame is graphical."
  (declare (indent 2))
  `(let* ((dir (make-temp-file "fst-" t))
          (font-setup-os-release-file (expand-file-name "os-release" dir))
          (font-setup-declined-file (expand-file-name "declined" dir))
          (font-setup--checked nil)
          (after-make-frame-functions nil)
          (noninteractive nil)
          (system-type 'gnu/linux)
          (fst-graphic t)
          (fst-warnings nil) (fst-timers nil))
     (unwind-protect
         (fst-with-fonts ,found
           (with-temp-file font-setup-os-release-file (insert ,os-text))
           (cl-letf (((symbol-function 'display-graphic-p)
                      (lambda (&rest _) fst-graphic))
                     ((symbol-function 'display-warning)
                      (lambda (_type msg &rest _) (push msg fst-warnings)))
                     ((symbol-function 'run-with-idle-timer)
                      (lambda (_secs _repeat fn &rest args)
                        (push (cons fn args) fst-timers)))
                     ((symbol-function 'y-or-n-p)
                      (lambda (&rest _) (error "Prompted in a hook")))
                     ((symbol-function 'yes-or-no-p)
                      (lambda (&rest _) (error "Prompted in a hook"))))
             ,@body))
       (delete-directory dir t))))

(ert-deftest fst-frame-on-forky-warns-once-naming-both-packages ()
  "Both missing fonts are named in one warning, and nothing is offered."
  (fst-with-frame "ID=debian\nVERSION_CODENAME=forky\n" nil
    (font-setup--on-frame 'frame)
    (should (equal fst-warnings
                   '("Missing fonts. Install them with: sudo apt install \
fonts-jetbrains-mono fonts-nerd-symbols")))
    (should-not fst-timers)))

(ert-deftest fst-frame-on-trixie-defers-the-offer ()
  "The offer waits for idle and carries the frame it is for."
  (fst-with-frame "ID=debian\nVERSION_CODENAME=trixie\n"
      (list "JetBrains Mono")
    (font-setup--on-frame 'frame)
    (should-not fst-warnings)
    (should (equal fst-timers '((font-setup--offer frame))))))

(ert-deftest fst-frame-after-a-decline-offers-nothing ()
  "A recorded no is honoured by the hook."
  (fst-with-frame "ID=debian\nVERSION_CODENAME=bookworm\n"
      (list "JetBrains Mono")
    (write-region "" nil font-setup-declined-file)
    (font-setup--on-frame 'frame)
    (should-not fst-timers)))

(ert-deftest fst-frame-runs-once ()
  "A second graphical frame does not ask again."
  (fst-with-frame "ID=debian\nVERSION_CODENAME=trixie\n" nil
    (font-setup--on-frame 'frame)
    (font-setup--on-frame 'frame)
    (should (equal fst-timers '((font-setup--offer frame))))))

(ert-deftest fst-frame-on-a-tty-does-nothing ()
  "A tty frame applies nothing, schedules nothing and is not the check."
  (fst-with-frame "ID=debian\nVERSION_CODENAME=trixie\n" nil
    (setq fst-graphic nil)
    (font-setup--on-frame 'frame)
    (should-not fst-faces)
    (should-not fst-pins)
    (should-not fst-timers)
    (should-not fst-warnings)
    (should-not font-setup--checked)))

(ert-deftest fst-frame-hook-is-removed-after-a-graphical-frame ()
  "The check does not stay on `after-make-frame-functions'."
  (fst-with-frame "ID=debian\nVERSION_CODENAME=trixie\n" nil
    (add-hook 'after-make-frame-functions #'font-setup--on-frame)
    (font-setup--on-frame 'frame)
    (should-not (memq #'font-setup--on-frame after-make-frame-functions))))

;;; Batch mode

(ert-deftest fst-batch-enables-nothing-and-prompts-nothing ()
  "In batch the hook is not added and no frame check runs."
  (should noninteractive)
  (let ((after-make-frame-functions nil)
        (font-setup--checked nil))
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (&rest _) (error "Prompted in batch")))
              ((symbol-function 'yes-or-no-p)
               (lambda (&rest _) (error "Prompted in batch")))
              ((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'run-with-idle-timer)
               (lambda (&rest _) (error "Scheduled in batch"))))
      (font-setup-enable)
      (font-setup--on-frame (selected-frame))
      (font-setup--offer (selected-frame))
      (should-not after-make-frame-functions)
      (should-not font-setup--checked))
    ;; A daemon in batch has no graphical frame, which is the hook path.
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
      (font-setup-enable)
      (should-not after-make-frame-functions))))

;;; The offer

(defmacro fst-with-offer (answer &rest body)
  "Run BODY interactively with `yes-or-no-p' returning ANSWER.
`fst-installed' says whether the install ran. `fst-prompt-frame' is the
frame selected when the question was asked. `fst-symbols-found' says
whether `find-font' finds the symbols font."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "fst-" t))
          (font-setup-declined-file (expand-file-name "sub/declined" dir))
          (noninteractive nil)
          (fst-graphic t)
          (fst-installed nil) (fst-prompt-frame nil) (fst-timers nil)
          (fst-symbols-found nil)
          (after-make-frame-functions nil))
     (unwind-protect
         (cl-letf (((symbol-function 'yes-or-no-p)
                    (lambda (&rest _)
                      (setq fst-prompt-frame (selected-frame))
                      ,answer))
                   ((symbol-function 'y-or-n-p)
                    (lambda (&rest _) (error "Asked with y-or-n-p")))
                   ((symbol-function 'display-graphic-p)
                    (lambda (&rest _) fst-graphic))
                   ((symbol-function 'run-with-idle-timer)
                    (lambda (_secs _repeat fn &rest args)
                      (push (cons fn args) fst-timers)))
                   ((symbol-function 'find-font)
                    (lambda (&rest _) (and fst-symbols-found 'entity)))
                   ((symbol-function 'font-setup-install-symbols)
                    (lambda () (setq fst-installed t)))
                   ((symbol-function 'message) #'ignore))
           ,@body)
       (delete-directory dir t))))

(ert-deftest fst-no-records-the-decline ()
  "A no writes the declined file, which stops the next offer."
  (fst-with-offer nil
    (font-setup--offer (selected-frame))
    (should-not fst-installed)
    (should (file-exists-p font-setup-declined-file))))

(ert-deftest fst-yes-installs ()
  "A yes starts the install and records nothing."
  (fst-with-offer t
    (font-setup--offer (selected-frame))
    (should fst-installed)
    (should-not (file-exists-p font-setup-declined-file))))

(ert-deftest fst-offer-asks-on-its-own-frame ()
  "The question is asked with the frame it is for selected.
Batch has one frame, so the frame is a stand-in and selecting it is
recorded rather than done."
  (fst-with-offer t
    (let ((selected nil))
      (cl-letf (((symbol-function 'frame-live-p) (lambda (_f) t))
                ((symbol-function 'select-frame)
                 (lambda (frame &rest _) (push frame selected))))
        (font-setup--offer 'gui-frame))
      (should fst-installed)
      (should (eq (car (last selected)) 'gui-frame)))))

(ert-deftest fst-offer-on-a-tty-waits-for-a-graphical-frame ()
  "A frame that is not graphical defers the offer to the next one."
  (fst-with-offer t
    (setq fst-graphic nil)
    (font-setup--offer (selected-frame))
    (should-not fst-prompt-frame)
    (should (memq #'font-setup--offer-on-frame after-make-frame-functions))
    ;; Another tty frame keeps waiting.
    (font-setup--offer-on-frame 'tty-frame)
    (should-not fst-timers)
    ;; A graphical frame gets the offer, and the wait ends.
    (setq fst-graphic t)
    (font-setup--offer-on-frame 'gui-frame)
    (should (equal fst-timers '((font-setup--offer gui-frame))))
    (should-not (memq #'font-setup--offer-on-frame
                      after-make-frame-functions))))

(ert-deftest fst-offer-skips-a-font-installed-meanwhile ()
  "A font that appeared while the offer waited is not offered again."
  (fst-with-offer t
    (setq fst-symbols-found t)
    (font-setup--offer (selected-frame))
    (should-not fst-prompt-frame)
    (should-not fst-installed)))

(ert-deftest fst-offer-skips-a-decline-recorded-meanwhile ()
  "A no recorded by another Emacs while the offer waited is honoured."
  (fst-with-offer t
    (make-directory (file-name-directory font-setup-declined-file) t)
    (write-region "" nil font-setup-declined-file nil 'silent)
    (font-setup--offer (selected-frame))
    (should-not fst-prompt-frame)
    (should-not fst-installed)
    (should-not (memq #'font-setup--offer-on-frame
                      after-make-frame-functions))))

(ert-deftest fst-offer-on-a-closed-frame-waits-for-a-graphical-frame ()
  "A frame closed before the idle timer fired does not get the question."
  (fst-with-offer t
    (font-setup--offer 'not-a-live-frame)
    (should-not fst-prompt-frame)
    (should (memq #'font-setup--offer-on-frame
                  after-make-frame-functions))))

;;; The install pipeline

(defconst fst-archive-bytes "pretend archive"
  "What the stubbed download writes.")

(defconst fst-listing
  "LICENSE\nREADME.md\nSymbolsNerdFont-Regular.ttf\n\
SymbolsNerdFontMono-Regular.ttf\n10-nerd-font-symbols.conf\n"
  "What the stubbed `tar -t' prints.")

(defun fst-arg-after (flag command)
  "Return the element of COMMAND after FLAG."
  (cadr (member flag command)))

(defmacro fst-with-install (system sha &rest body)
  "Run BODY with every step of the install stubbed, as SYSTEM.
SHA is the expected archive hash. `fst-ran' collects each step as
\(NAME . COMMAND), and `fst-dest' is the install directory. `fst-messages'
collects what was reported. `fst-extract-as' says what the extract step
leaves at the entry: `file', `symlink' or `directory'."
  (declare (indent 2))
  `(let* ((root (make-temp-file "fst-" t))
          (fst-dest (expand-file-name "fonts" root))
          (font-setup-install-directory fst-dest)
          (font-setup-download-sha256 ,sha)
          (system-type ,system)
          (fst-ran nil) (fst-tmp nil) (fst-messages nil)
          (fst-extract-as 'file))
     (unwind-protect
         (cl-letf (((symbol-function 'font-setup--run)
                    (lambda (name command tmp then)
                      (push (cons name command) fst-ran)
                      (when tmp (setq fst-tmp tmp))
                      (pcase name
                        ("curl"
                         ;; No handlers, or jka-compr would compress it.
                         (let ((file-name-handler-alist nil))
                           (write-region fst-archive-bytes nil
                                         (fst-arg-after "--output" command)
                                         nil 'silent))
                         (funcall then ""))
                        ("tar-list" (funcall then fst-listing))
                        ("tar-extract"
                         ;; tar would write the named entry under -C.
                         (let ((entry (expand-file-name
                                       (car (last command))
                                       (fst-arg-after "-C" command))))
                           (pcase fst-extract-as
                             ;; Not 644, so the install must set the mode.
                             ('file (with-temp-file entry
                                      (insert "font bytes"))
                                    (set-file-modes entry #o600))
                             ('symlink
                              (let ((target (expand-file-name "elsewhere"
                                                              root)))
                                (with-temp-file target (insert "elsewhere"))
                                (make-symbolic-link target entry)))
                             ('directory (make-directory entry))))
                         (funcall then ""))
                        (_ (funcall then "")))))
                   ((symbol-function 'clear-font-cache) #'ignore)
                   ((symbol-function 'message)
                    (lambda (fmt &rest args)
                      (push (apply #'format fmt args) fst-messages))))
           ,@body)
       (delete-directory root t))))

(defun fst-good-sha ()
  "The sha256 of what the stubbed download writes."
  (secure-hash 'sha256 fst-archive-bytes))

(ert-deftest fst-sha256-check ()
  "A file passes only against its own hash."
  (let ((file (make-temp-file "fst-")))
    (unwind-protect
        (progn
          (with-temp-file file (insert fst-archive-bytes))
          (should (font-setup--sha256-ok-p file (fst-good-sha)))
          (should (font-setup--sha256-ok-p file (upcase (fst-good-sha))))
          (should-not (font-setup--sha256-ok-p file (make-string 64 ?0))))
      (delete-file file))))

(ert-deftest fst-install-refuses-a-wrong-hash ()
  "A mismatched archive is never listed, extracted or installed."
  (fst-with-install 'gnu/linux (make-string 64 ?0)
    (font-setup-install-symbols)
    (should (equal (mapcar #'car fst-ran) '("curl")))
    (should-not (file-exists-p fst-dest))
    (should-not (file-exists-p fst-tmp))))

(ert-deftest fst-install-on-linux-copies-the-mono-ttf-and-runs-fc-cache ()
  "Only the Mono ttf lands, and fc-cache is run on its directory."
  (fst-with-install 'gnu/linux (fst-good-sha)
    (font-setup-install-symbols)
    (should (equal (mapcar #'car (reverse fst-ran))
                   '("curl" "tar-list" "tar-extract" "fc-cache")))
    (should (equal (car (last (cdr (assoc "tar-extract" fst-ran))))
                   "SymbolsNerdFontMono-Regular.ttf"))
    (should (equal (cdr (assoc "fc-cache" fst-ran))
                   (list "fc-cache" "-f" fst-dest)))
    (should (equal (directory-files fst-dest nil "\\`[^.]")
                   '("SymbolsNerdFontMono-Regular.ttf")))
    (should (= (file-modes (expand-file-name
                            "SymbolsNerdFontMono-Regular.ttf" fst-dest))
               #o644))
    (should-not (file-exists-p fst-tmp))))

(ert-deftest fst-a-failed-rename-leaves-no-temp-file ()
  "A directory at the destination fails the install and leaves no part file."
  (fst-with-install 'gnu/linux (fst-good-sha)
    (let ((dest (expand-file-name "SymbolsNerdFontMono-Regular.ttf"
                                  fst-dest)))
      ;; Not empty, so the rename cannot replace it.
      (make-directory dest t)
      (write-region "" nil (expand-file-name "keep" dest) nil 'silent)
      (font-setup-install-symbols)
      (should (file-directory-p dest))
      (should-not (directory-files fst-dest nil "\\`\\.font-setup-"))
      (should (seq-find (lambda (m)
                          (string-prefix-p "font-setup: install failed" m))
                        fst-messages))
      (should-not (assoc "fc-cache" fst-ran))
      (should-not (file-exists-p fst-tmp)))))

(ert-deftest fst-install-on-macos-skips-fc-cache ()
  "On macOS there is no fc-cache step."
  (fst-with-install 'darwin (fst-good-sha)
    (font-setup-install-symbols)
    (should (equal (mapcar #'car (reverse fst-ran))
                   '("curl" "tar-list" "tar-extract")))
    (should (file-exists-p
             (expand-file-name "SymbolsNerdFontMono-Regular.ttf" fst-dest)))))

(ert-deftest fst-install-refuses-a-url-that-is-not-https ()
  "Nothing runs for a plain http URL."
  (fst-with-install 'gnu/linux (fst-good-sha)
    (let ((font-setup-download-url "http://example.com/%s.tar.xz"))
      (font-setup-install-symbols))
    (should-not fst-ran)))

(ert-deftest fst-curl-is-bounded-and-https-only ()
  "The download ignores ~/.curlrc, stays on https and is bounded."
  (fst-with-install 'gnu/linux (make-string 64 ?0)
    (font-setup-install-symbols)
    (let ((curl (cdr (assoc "curl" fst-ran))))
      (should (equal (cadr curl) "-q"))
      (should (member "--fail" curl))
      (should (equal (fst-arg-after "--proto" curl) "=https"))
      (should (equal (fst-arg-after "--proto-redir" curl) "=https"))
      (should (fst-arg-after "--max-time" curl))
      (should (fst-arg-after "--max-filesize" curl)))))

(ert-deftest fst-tar-extract-ends-its-options-before-the-entry ()
  "An entry name is never read as a tar option."
  (fst-with-install 'gnu/linux (fst-good-sha)
    (font-setup-install-symbols)
    (should (equal (last (cdr (assoc "tar-extract" fst-ran)) 2)
                   '("--" "SymbolsNerdFontMono-Regular.ttf")))))

(ert-deftest fst-install-replaces-a-symlink-at-the-destination ()
  "A link at the destination is replaced, and its target is untouched."
  (fst-with-install 'gnu/linux (fst-good-sha)
    (let ((target (expand-file-name "scratch.ttf" root))
          (dest (expand-file-name "SymbolsNerdFontMono-Regular.ttf"
                                  fst-dest)))
      (make-directory fst-dest t)
      (with-temp-file target (insert "scratch"))
      (set-file-modes target #o600)
      (make-symbolic-link target dest)
      (font-setup-install-symbols)
      (should-not (file-symlink-p dest))
      (should (file-regular-p dest))
      (should (equal (with-temp-buffer (insert-file-contents dest)
                                       (buffer-string))
                     "font bytes"))
      (should (equal (with-temp-buffer (insert-file-contents target)
                                       (buffer-string))
                     "scratch"))
      (should (= (file-modes target) #o600))
      (should (equal (directory-files fst-dest nil "\\`[^.]")
                     '("SymbolsNerdFontMono-Regular.ttf"))))))

(ert-deftest fst-install-refuses-an-extracted-symlink ()
  "An entry that tar left as a link is not installed."
  (fst-with-install 'gnu/linux (fst-good-sha)
    (setq fst-extract-as 'symlink)
    (font-setup-install-symbols)
    (should (seq-find (lambda (m) (string-suffix-p "is not a regular file" m))
                      fst-messages))
    (should-not (file-exists-p fst-dest))
    (should-not (assoc "fc-cache" fst-ran))
    (should-not (file-exists-p fst-tmp))))

(ert-deftest fst-install-refuses-an-extracted-directory ()
  "An entry that tar left as a directory is not installed."
  (fst-with-install 'gnu/linux (fst-good-sha)
    (setq fst-extract-as 'directory)
    (font-setup-install-symbols)
    (should (seq-find (lambda (m) (string-suffix-p "is not a regular file" m))
                      fst-messages))
    (should-not (file-exists-p fst-dest))
    (should-not (assoc "fc-cache" fst-ran))
    (should-not (file-exists-p fst-tmp))))

(ert-deftest fst-an-error-in-a-step-is-reported-and-cleaned-up ()
  "A step that signals reports the error and leaves no scratch directory."
  (fst-with-install 'gnu/linux (fst-good-sha)
    ;; A file where a directory must go makes `make-directory' signal.
    (let ((blocker (expand-file-name "blocker" root)))
      (with-temp-file blocker (insert ""))
      (let ((font-setup-install-directory
             (expand-file-name "fonts" blocker)))
        (font-setup-install-symbols)))
    (should (seq-find (lambda (m) (string-prefix-p "font-setup: install failed"
                                                   m))
                      fst-messages))
    (should-not (assoc "fc-cache" fst-ran))
    (should-not (file-exists-p fst-tmp))))

(ert-deftest fst-pick-member-takes-only-the-mono-ttf ()
  "The non-Mono font and the other files are passed over."
  (should (equal (font-setup--pick-member fst-listing
                                          "SymbolsNerdFontMono-Regular.ttf")
                 "SymbolsNerdFontMono-Regular.ttf"))
  (should (equal (font-setup--pick-member
                  "./SymbolsNerdFont-Regular.ttf\n\
./SymbolsNerdFontMono-Regular.ttf\n"
                  "SymbolsNerdFontMono-Regular.ttf")
                 "./SymbolsNerdFontMono-Regular.ttf"))
  (should-not (font-setup--pick-member "LICENSE\nSymbolsNerdFont-Regular.ttf\n"
                                       "SymbolsNerdFontMono-Regular.ttf")))

(ert-deftest fst-pick-member-refuses-an-escaping-entry ()
  "An entry that would land outside the scratch directory is never picked."
  (should-not (font-setup--pick-member
               "../SymbolsNerdFontMono-Regular.ttf\n\
/tmp/SymbolsNerdFontMono-Regular.ttf\n"
               "SymbolsNerdFontMono-Regular.ttf")))

(provide 'font-setup-tests)
;;; font-setup-tests.el ends here
