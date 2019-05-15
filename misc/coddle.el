
(setq coddle-highlights
  '(("\\blam\\b\\|\\bfor\\b\\|\\blet\\b\\|\bunpack\\b\\|\\bin\\b"
     . font-lock-keyword-face)
    ("E\\|A"                            . font-lock-builtin-face)
    ("->\\|=>\\|\\.\\|=\\|;\\|::"       . font-lock-variable-name-face)
    ("Real\\|Int\\|Str"                 . font-lock-type-face)
    (":t\\|:passes\\|:p\\|:time"        . font-lock-preprocessor-face)))

(setq coddle-mode-syntax-table
      (let ((synTable (make-syntax-table)))
        (modify-syntax-entry ?-  ". 12" synTable)
        (modify-syntax-entry ?>  ". 1"  synTable)
        (modify-syntax-entry ?   ". 2"  synTable)
        (modify-syntax-entry ?\n ">"    synTable)
        synTable))

(define-derived-mode coddle-mode fundamental-mode "coddle"
  (setq font-lock-defaults '(coddle-highlights))
  (setq-local syntax-propertize-function
              (syntax-propertize-rules (".>\\( +\\)" (1 "."))))
   (set-syntax-table coddle-mode-syntax-table))

(add-to-list 'auto-mode-alist '("\\.cd\\'"  . coddle-mode))
(add-to-list 'auto-mode-alist '("\\.cod\\'" . coddle-mode))
