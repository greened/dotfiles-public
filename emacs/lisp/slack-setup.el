;; From http://endlessparentheses.com/mold-slack-entirely-to-your-liking-with-emacs.html

(with-eval-after-load 'tracking
  (define-key tracking-mode-map [f11]
    #'tracking-next-buffer))
