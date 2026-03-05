;;; ox-canvas-quiz.el --- Org export backend for Canvas quiz .md files  -*- lexical-binding: t; -*-

;;; Commentary:
;; Exports Org quiz files to the text2qti .md format for Canvas quiz import.
;;
;; Supported question types:
;;   Multiple Choice, Multiple Answers, Numerical, Short Answer,
;;   Essay, and File Upload.
;;
;; Additional features:
;;   Per-question feedback (general, correct-only, incorrect-only),
;;   per-answer feedback, point values, question titles, answer shuffling,
;;   and multi-paragraph question/answer text.
;;
;; Usage:
;;   Interactive: C-c C-e Q q  (quiz .md)
;;                C-c C-e Q z  (quiz .zip via text2qti)
;;                C-c C-e Q b  (question bank .md)
;;                C-c C-e Q B  (question bank .zip via text2qti)
;;   Batch: emacs --batch FILE.org -l ox-canvas-quiz.el -f org-canvas-quiz-export-to-md-batch
;;          emacs --batch FILE.org -l ox-canvas-quiz.el -f org-canvas-quiz-export-to-qti-batch
;;          emacs --batch FILE.org -l ox-canvas-quiz.el -f org-canvas-quiz-export-to-bank-md-batch
;;          emacs --batch FILE.org -l ox-canvas-quiz.el -f org-canvas-quiz-export-to-bank-qti-batch

;;; Code:

(require 'org)
(require 'org-element)
(require 'ox)
(require 'seq)

(org-export-define-backend 'canvas-quiz
  '((template . (lambda (_contents _info) "")))
  :menu-entry
  '(?Q "Export to Canvas Quiz"
       ((?q "As quiz .md file" org-canvas-quiz-export-to-md)
        (?z "As quiz .zip (QTI) via text2qti" org-canvas-quiz-export-to-qti)
        (?b "As question bank .md file" org-canvas-quiz-export-to-bank-md)
        (?B "As question bank .zip (QTI) via text2qti" org-canvas-quiz-export-to-bank-qti))))

;;; Markup interpretation

(defun org-canvas-quiz--interpret-object (obj)
  "Convert a single Org element/object OBJ to plain text with backtick code.
Non-plain-text objects may consume trailing whitespace into their
`:post-blank' property; this function re-appends those spaces."
  (if (eq (org-element-type obj) 'plain-text)
      obj
    (let ((text
           (pcase (org-element-type obj)
             ((or 'code 'verbatim)
              (format "`%s`" (org-element-property :value obj)))
             ((or 'bold 'italic 'underline 'strike-through)
              (org-canvas-quiz--interpret-contents obj))
             ('latex-fragment (org-element-property :value obj))
             ('line-break " ")
             ('subscript
              (concat "_" (org-canvas-quiz--interpret-contents obj)))
             ('superscript
              (concat "^" (org-canvas-quiz--interpret-contents obj)))
             ('link
              (or (org-canvas-quiz--interpret-contents obj)
                  (org-element-property :raw-link obj)))
             ('entity
              (or (org-element-property :utf-8 obj)
                  (org-element-property :ascii obj)))
             (_ (or (org-canvas-quiz--interpret-contents obj) ""))))
          (post-blank (or (org-element-property :post-blank obj) 0)))
      (if (> post-blank 0)
          (concat text (make-string post-blank ?\s))
        text))))

(defun org-canvas-quiz--interpret-contents (element)
  "Walk child objects of ELEMENT, concatenating their text."
  (mapconcat #'org-canvas-quiz--interpret-object
             (org-element-contents element) ""))

;;; Properties and keyword helpers

(defun org-canvas-quiz--get-property (headline key)
  "Get the value of property KEY from HEADLINE's properties drawer."
  (org-element-map headline 'node-property
    (lambda (np)
      (when (string-equal-ignore-case (org-element-property :key np) key)
        (org-element-property :value np)))
    nil t))

(defun org-canvas-quiz--get-keyword (tree key)
  "Extract the value of #+KEY: from parsed TREE."
  (org-element-map tree 'keyword
    (lambda (kw)
      (when (string-equal-ignore-case (org-element-property :key kw) key)
        (org-element-property :value kw)))
    nil t))

;;; Element extraction

(defun org-canvas-quiz--get-title (tree)
  "Extract #+TITLE: value from parsed TREE."
  (org-canvas-quiz--get-keyword tree "TITLE"))

(defun org-canvas-quiz--paragraph-text (para)
  "Extract single-line text from a paragraph element PARA."
  (let ((text (string-trim (org-canvas-quiz--interpret-contents para))))
    (replace-regexp-in-string "[ \t]*\n[ \t]*" " " text)))

(defun org-canvas-quiz--item-text-and-feedback (item)
  "Extract text and optional feedback from a list ITEM.
Returns (:text TEXT :feedback FEEDBACK-OR-NIL).
Splits on \"Feedback:\" whether it appears as a separate paragraph
or as a continuation within the same paragraph."
  (let ((full-text ""))
    (dolist (child (org-element-contents item))
      (when (eq (org-element-type child) 'paragraph)
        (let ((ptext (org-canvas-quiz--paragraph-text child)))
          (setq full-text (if (string-empty-p full-text)
                              ptext
                            (concat full-text " " ptext))))))
    (if (string-match "\\(.*?\\)[[:space:]]+Feedback:[[:space:]]*\\(.*\\)" full-text)
        (list :text (string-trim (match-string 1 full-text))
              :feedback (string-trim (match-string 2 full-text)))
      (list :text full-text :feedback nil))))

(defun org-canvas-quiz--item-text (item)
  "Extract text from a list ITEM element (backward-compatible)."
  (plist-get (org-canvas-quiz--item-text-and-feedback item) :text))

(defun org-canvas-quiz--parse-options (headline)
  "Parse checkbox list items under HEADLINE into option plists.
Returns list of (:text TEXT :correct BOOL :feedback FEEDBACK-OR-NIL)."
  (let (options)
    (org-element-map headline 'item
      (lambda (item)
        (when (org-element-property :checkbox item)
          (let ((tf (org-canvas-quiz--item-text-and-feedback item)))
            (push (list :text (plist-get tf :text)
                        :correct (eq (org-element-property :checkbox item) 'on)
                        :feedback (plist-get tf :feedback))
                  options)))))
    (nreverse options)))

(defun org-canvas-quiz--parse-accepted-answers (headline)
  "Parse plain list items without checkboxes from HEADLINE as accepted answers."
  (let (answers)
    (org-element-map headline 'item
      (lambda (item)
        (unless (org-element-property :checkbox item)
          (let ((text (org-canvas-quiz--item-text item)))
            (when (> (length text) 0)
              (push text answers))))))
    (nreverse answers)))

(defun org-canvas-quiz--question-text (headline)
  "Extract question body paragraphs from HEADLINE section.
Multiple paragraphs are joined with double newlines for
multi-paragraph support in text2qti."
  (let (paragraphs)
    (dolist (child (org-element-contents headline))
      (when (eq (org-element-type child) 'section)
        (dolist (sec-child (org-element-contents child))
          (when (eq (org-element-type sec-child) 'paragraph)
            (push (org-canvas-quiz--paragraph-text sec-child) paragraphs)))))
    (string-join (nreverse paragraphs) "\n\n")))

;;; Question type detection

(defun org-canvas-quiz--question-type (headline)
  "Determine question type from HEADLINE properties and checkbox structure.
Returns one of: \"mc\", \"ma\", \"numerical\", \"short-answer\",
\"essay\", \"upload\", or nil if the question cannot be exported."
  (let ((type-prop (org-canvas-quiz--get-property headline "Type")))
    (cond
     ((and type-prop (string-match-p "\\`[Nn]umerical\\'" type-prop))
      "numerical")
     ((and type-prop (string-match-p "\\`[Ss]hort[- ]?[Aa]nswer\\'" type-prop))
      "short-answer")
     ((and type-prop (string-match-p "\\`[Ee]ssay\\'" type-prop))
      "essay")
     ((and type-prop (string-match-p "\\`[Uu]pload\\'" type-prop))
      "upload")
     (t
      (let ((options (org-canvas-quiz--parse-options headline))
            (correct-count 0))
        (dolist (opt options)
          (when (plist-get opt :correct)
            (setq correct-count (1+ correct-count))))
        (cond
         ((> correct-count 1) "ma")
         ((= correct-count 1) "mc")
         (t nil)))))))

;;; Question collection

(defun org-canvas-quiz--skip-section-p (headline)
  "Return non-nil if HEADLINE is a section to skip during export."
  (and (eq (org-element-type headline) 'headline)
       (= (org-element-property :level headline) 1)
       (let ((title (string-trim (org-element-property :raw-value headline))))
         (or (string-match-p "\\`Short Answer Questions\\'" title)
             (string-match-p "\\`Review Questions\\'" title)))))

(defun org-canvas-quiz--collect-questions (tree)
  "Collect eligible questions from TREE with type and metadata.
Skips :noexport: headlines, Short Answer Questions, and Review Questions."
  (let (questions)
    (org-element-map tree 'headline
      (lambda (hl)
        (when (and (= (org-element-property :level hl) 2)
                   (not (member "noexport" (org-element-property :tags hl)))
                   (let ((parent (org-element-property :parent hl)))
                     (not (org-canvas-quiz--skip-section-p parent))))
          (let ((qtype (org-canvas-quiz--question-type hl))
                (text (org-canvas-quiz--question-text hl)))
            (when (and qtype (> (length text) 0))
              (let ((q (list :text text :type qtype)))
                ;; Type-specific data
                (pcase qtype
                  ("mc"
                   (setq q (plist-put q :options
                                      (org-canvas-quiz--parse-options hl))))
                  ("ma"
                   (setq q (plist-put q :options
                                      (org-canvas-quiz--parse-options hl))))
                  ("numerical"
                   (setq q (plist-put q :answer
                                      (org-canvas-quiz--get-property hl "Answer")))
                   (setq q (plist-put q :tolerance
                                      (or (org-canvas-quiz--get-property hl "Tolerance")
                                          "0"))))
                  ("short-answer"
                   (setq q (plist-put q :answers
                                      (org-canvas-quiz--parse-accepted-answers hl)))))
                ;; Feedback
                (let ((fb (org-canvas-quiz--get-property hl "Feedback"))
                      (cfb (org-canvas-quiz--get-property hl "CorrectFeedback"))
                      (ifb (org-canvas-quiz--get-property hl "IncorrectFeedback")))
                  (when fb  (setq q (plist-put q :feedback fb)))
                  (when cfb (setq q (plist-put q :correct-feedback cfb)))
                  (when ifb (setq q (plist-put q :incorrect-feedback ifb))))
                ;; Points
                (let ((pts (org-canvas-quiz--get-property hl "Points")))
                  (when pts (setq q (plist-put q :points pts))))
                ;; Title (always use the headline text)
                (setq q (plist-put q :title
                                   (org-element-property :raw-value hl)))
                (push q questions)))))))
    (nreverse questions)))

;;; Output formatting

(defun org-canvas-quiz--indent-continuation (text indent)
  "Indent continuation lines/paragraphs in TEXT by INDENT spaces.
The first line is returned as-is.  Subsequent lines (after the
first newline) are prefixed with INDENT spaces.  Double newlines
(paragraph breaks) are preserved with blank lines between
indented paragraphs."
  (let ((pad (make-string indent ?\s)))
    (replace-regexp-in-string
     "\n"
     (concat "\n" pad)
     text)))

(defun org-canvas-quiz--format-question-prefix (n q)
  "Format the title and points prefix lines for question number N, plist Q.
Returns a string (possibly empty) to prepend before the question line."
  (let ((lines (list (format "Title: %s" (plist-get q :title)))))
    (when-let ((pts (plist-get q :points)))
      (push (format "Points: %s" pts) lines))
    (concat (string-join (nreverse lines) "\n") "\n")))

(defun org-canvas-quiz--format-question-feedback (q)
  "Format per-question feedback lines for question plist Q.
Returns a string (possibly empty) with ... / + / - lines."
  (let (lines)
    (when-let ((fb (plist-get q :feedback)))
      (push (format "... %s" fb) lines))
    (when-let ((cfb (plist-get q :correct-feedback)))
      (push (format "+ %s" cfb) lines))
    (when-let ((ifb (plist-get q :incorrect-feedback)))
      (push (format "- %s" ifb) lines))
    (if lines
        (concat "\n" (string-join (nreverse lines) "\n"))
      "")))

(defun org-canvas-quiz--format-mc-option (opt letter)
  "Format a multiple-choice option OPT with LETTER label.
Includes per-answer feedback if present."
  (let ((line (format "%s%c) %s"
                      (if (plist-get opt :correct) "*" "")
                      letter
                      (plist-get opt :text))))
    (if-let ((fb (plist-get opt :feedback)))
        (format "%s\n... %s" line fb)
      line)))

(defun org-canvas-quiz--format-ma-option (opt)
  "Format a multiple-answers option OPT with checkbox syntax.
Includes per-answer feedback if present."
  (let ((line (format "%s %s"
                      (if (plist-get opt :correct) "[*]" "[ ]")
                      (plist-get opt :text))))
    (if-let ((fb (plist-get opt :feedback)))
        (format "%s\n... %s" line fb)
      line)))

(defun org-canvas-quiz--format-question-stem (n text)
  "Format question number N with TEXT, handling multi-paragraph indentation."
  (let* ((prefix (format "%d. " n))
         (indent (length prefix)))
    (concat prefix (org-canvas-quiz--indent-continuation text indent))))

(defun org-canvas-quiz--format-mc-block (n q)
  "Format MC question number N with plist Q (options with letter labels)."
  (let ((qlines (list (concat
                       (org-canvas-quiz--format-question-prefix n q)
                       (org-canvas-quiz--format-question-stem n (plist-get q :text))
                       (org-canvas-quiz--format-question-feedback q))))
        (letter ?a))
    (dolist (opt (plist-get q :options))
      (push (org-canvas-quiz--format-mc-option opt letter) qlines)
      (setq letter (1+ letter)))
    (string-join (nreverse qlines) "\n")))

(defun org-canvas-quiz--format-standalone (n q)
  "Format a standalone (non-GROUP) question number N with plist Q."
  (let ((prefix (org-canvas-quiz--format-question-prefix n q))
        (stem (org-canvas-quiz--format-question-stem n (plist-get q :text)))
        (fb (org-canvas-quiz--format-question-feedback q)))
    (pcase (plist-get q :type)
      ((or "mc" "ma")
       (let ((qlines (list (concat prefix stem fb)))
             (mc-p (string= (plist-get q :type) "mc")))
         (if mc-p
             (let ((letter ?a))
               (dolist (opt (plist-get q :options))
                 (push (org-canvas-quiz--format-mc-option opt letter) qlines)
                 (setq letter (1+ letter))))
           (dolist (opt (plist-get q :options))
             (push (org-canvas-quiz--format-ma-option opt) qlines)))
         (string-join (nreverse qlines) "\n")))
      ("numerical"
       (format "%s%s%s\n= %s +- %s"
               prefix stem fb
               (plist-get q :answer)
               (plist-get q :tolerance)))
      ("short-answer"
       (let ((qlines (list (concat prefix stem fb))))
         (dolist (ans (plist-get q :answers))
           (push (format "* %s" ans) qlines))
         (string-join (nreverse qlines) "\n")))
      ("essay"
       (format "%s%s%s\n____" prefix stem fb))
      ("upload"
       (format "%s%s%s\n^^^^" prefix stem fb)))))

(defun org-canvas-quiz--format-output (title questions &optional shuffle)
  "Format TITLE and QUESTIONS list into the text2qti .md string.
When SHUFFLE is non-nil, include `shuffle answers: true'.
MC questions without custom points go in a GROUP for random
selection; all other questions are standalone."
  (let* (;; MC without custom points → GROUP; everything else → standalone
         (group-qs (seq-filter
                    (lambda (q) (and (string= (plist-get q :type) "mc")
                                     (not (plist-get q :points))))
                    questions))
         (standalone-qs (seq-filter
                         (lambda (q) (not (and (string= (plist-get q :type) "mc")
                                               (not (plist-get q :points)))))
                         questions))
         (parts nil)
         (n 1))
    ;; Title
    (push (format "Quiz Title: %s" title) parts)
    ;; Shuffle setting
    (when shuffle
      (push "shuffle answers: true" parts))
    ;; MC GROUP
    (when group-qs
      (push (format "GROUP\npick: %d\npoints per question: 1"
                    (min 10 (length group-qs)))
            parts)
      (dolist (q group-qs)
        (push (org-canvas-quiz--format-mc-block n q) parts)
        (setq n (1+ n)))
      (push "END_GROUP" parts))
    ;; Standalone questions
    (dolist (q standalone-qs)
      (push (org-canvas-quiz--format-standalone n q) parts)
      (setq n (1+ n)))
    (concat (string-join (nreverse parts) "\n\n") "\n")))

(defun org-canvas-quiz--format-bank-output (title questions)
  "Format TITLE and QUESTIONS list into a text2qti question bank string.
All questions are standalone (no GROUP blocks, no shuffle setting)."
  (let ((parts nil)
        (n 1))
    (push (format "Question Bank Title: %s" title) parts)
    (dolist (q questions)
      (push (org-canvas-quiz--format-standalone n q) parts)
      (setq n (1+ n)))
    (concat (string-join (nreverse parts) "\n\n") "\n")))

;;; Entry points

(defun org-canvas-quiz-export-to-md (&optional _async _subtreep _visible-only _body-only _ext-plist)
  "Export current Org buffer to a Canvas quiz .md file.
Returns the output file path."
  (interactive)
  (let* ((tree (org-element-parse-buffer))
         (title (org-canvas-quiz--get-title tree))
         (shuffle-val (org-canvas-quiz--get-keyword tree "QUIZ_SHUFFLE"))
         (shuffle (and shuffle-val
                       (member (downcase (string-trim shuffle-val))
                               '("yes" "true"))))
         (questions (org-canvas-quiz--collect-questions tree))
         (output (org-canvas-quiz--format-output title questions shuffle))
         (outfile (concat (file-name-sans-extension (buffer-file-name)) ".md")))
    (with-temp-file outfile
      (insert output))
    (message "Exported %d questions to %s" (length questions) outfile)
    outfile))

(defun org-canvas-quiz-export-to-qti (&optional _async _subtreep _visible-only _body-only _ext-plist)
  "Export current Org buffer to a QTI .zip file via text2qti.
First exports to .md, then runs text2qti to produce the .zip.
Returns the .zip file path."
  (interactive)
  (let* ((md-file (org-canvas-quiz-export-to-md))
         (text2qti (or (executable-find "text2qti")
                       (error "text2qti not found in PATH")))
         (default-directory (file-name-directory md-file))
         (exit-code (call-process text2qti nil "*text2qti*" nil
                                  (file-name-nondirectory md-file)))
         (zip-file (concat (file-name-sans-extension md-file) ".zip")))
    (unless (= exit-code 0)
      (pop-to-buffer "*text2qti*")
      (error "text2qti failed with exit code %d" exit-code))
    (message "Exported QTI zip: %s" zip-file)
    zip-file))

(defun org-canvas-quiz-export-to-md-batch ()
  "Batch entry point: export to .md and exit."
  (org-mode)
  (org-canvas-quiz-export-to-md)
  (kill-emacs 0))

(defun org-canvas-quiz-export-to-qti-batch ()
  "Batch entry point: export to .zip via text2qti and exit."
  (org-mode)
  (org-canvas-quiz-export-to-qti)
  (kill-emacs 0))

(defun org-canvas-quiz-export-to-bank-md (&optional _async _subtreep _visible-only _body-only _ext-plist)
  "Export current Org buffer to a Canvas question bank .md file.
Returns the output file path."
  (interactive)
  (let* ((tree (org-element-parse-buffer))
         (title (org-canvas-quiz--get-title tree))
         (questions (org-canvas-quiz--collect-questions tree))
         (output (org-canvas-quiz--format-bank-output title questions))
         (outfile (concat (file-name-sans-extension (buffer-file-name)) ".md")))
    (with-temp-file outfile
      (insert output))
    (message "Exported %d questions to bank %s" (length questions) outfile)
    outfile))

(defun org-canvas-quiz-export-to-bank-qti (&optional _async _subtreep _visible-only _body-only _ext-plist)
  "Export current Org buffer to a question bank QTI .zip via text2qti.
First exports to .md, then runs text2qti to produce the .zip.
Returns the .zip file path."
  (interactive)
  (let* ((md-file (org-canvas-quiz-export-to-bank-md))
         (text2qti (or (executable-find "text2qti")
                       (error "text2qti not found in PATH")))
         (default-directory (file-name-directory md-file))
         (exit-code (call-process text2qti nil "*text2qti*" nil
                                  (file-name-nondirectory md-file)))
         (zip-file (concat (file-name-sans-extension md-file) ".zip")))
    (unless (= exit-code 0)
      (pop-to-buffer "*text2qti*")
      (error "text2qti failed with exit code %d" exit-code))
    (message "Exported question bank QTI zip: %s" zip-file)
    zip-file))

(defun org-canvas-quiz-export-to-bank-md-batch ()
  "Batch entry point: export to question bank .md and exit."
  (org-mode)
  (org-canvas-quiz-export-to-bank-md)
  (kill-emacs 0))

(defun org-canvas-quiz-export-to-bank-qti-batch ()
  "Batch entry point: export to question bank .zip via text2qti and exit."
  (org-mode)
  (org-canvas-quiz-export-to-bank-qti)
  (kill-emacs 0))

(provide 'ox-canvas-quiz)
;;; ox-canvas-quiz.el ends here
