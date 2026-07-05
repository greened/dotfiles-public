;; ---------------------------------------------------------------------
;; Start an Emacs server so a remote emacsclient can open files here.
;;
;; The local (non-SSH) desktop Emacs hosts a server on a fixed unix socket,
;; ~/.ssh/emacs-server.  ssh/config.external RemoteForwards that socket to the
;; dev hosts, where emacs/emacsclient.py connects to it (emacsclient -s) and
;; rewrites the path to a /scp: TRAMP path so this Emacs opens the remote file.
;;
;; A unix socket (server-use-tcp nil) avoids the old TCP server-host setup that
;; crashed on macOS.  Guard on SSH_CLIENT so a remote Emacs never clobbers the
;; forwarded socket, and wrap in ignore-errors so a server hiccup can't abort
;; startup.
;; ---------------------------------------------------------------------
(require 'server)
(unless (getenv "SSH_CLIENT")
  (setq server-use-tcp nil)
  (setq server-name "emacs-server")
  (setq server-socket-dir (expand-file-name "~/.ssh"))
  (ignore-errors
    (unless (server-running-p)
      (server-start))))
