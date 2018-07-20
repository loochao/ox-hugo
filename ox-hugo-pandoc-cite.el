;;; ox-hugo-pandoc-cite.el --- Pandoc Citations support for ox-hugo -*- lexical-binding: t -*-

;; Authors: Kaushal Modi <kaushal.mod@gmail.com>
;; URL: https://ox-hugo.scripter.co

;;; Commentary:

;; *This is NOT a stand-alone package.*
;;
;; It is used by ox-hugo to add support for parsing Pandoc Citations.

;;; Code:

;; TODO: Change the defconst to defvar
(defvar org-hugo-pandoc-cite-pandoc-args-list
  '("-f" "markdown"
    "-t" "markdown-citations-simple_tables+pipe_tables"
    "--atx-headers")
  "Pandoc arguments used in `org-hugo-pandoc-cite--run-pandoc'.

-f markdown: Convert *from* Markdown

-t markdown: Convert *to* Markdown
  -citations: Remove the \"citations\" extension.  This will cause
              citations to be expanded instead of being included as
              markdown citations.

  -simple_tables: Remove the \"simple_tables\" style.

  +pipe_tables: Add the \"pipe_tables\" style insted that Blackfriday
                understands.

--atx-headers: Use \"# foo\" style heading for output markdown.

These arguments are added to the `pandoc' call in addition to the
\"--bibliography\", output file (\"-o\") and input file
arguments.")

(defvar org-hugo-pandoc-cite-pandoc-meta-data
  '("nocite" "csl")
  "List of meta-data fields specific to Pandoc.")

(defvar org-hugo-pandoc-cite--run-pandoc-buffer "*Pandoc Citations*"
  "Buffer to contain the `pandoc' run output and errors.")

(defun org-hugo-pandoc-cite--run-pandoc (orig-outfile bib-list)
  "Run the `pandoc' process and return the generated file name.

ORIG-OUTFILE is the Org exported file name.

BIB-LIST is a list of one or more bibliography files."
  ;; First kill the Pandoc run buffer if already exists (from a
  ;; previous run).
  (when (get-buffer org-hugo-pandoc-cite--run-pandoc-buffer)
    (kill-buffer org-hugo-pandoc-cite--run-pandoc-buffer))
  (let* ((pandoc-outfile (make-temp-file ;ORIG_FILE_BASENAME.RANDOM.md
                          (concat (file-name-base orig-outfile) ".")
                          nil ".md"))
         (bib-args (mapcar (lambda (bib-file)
                             (concat "--bibliography="
                                     bib-file))
                           bib-list))
         (pandoc-arg-list (append
                           org-hugo-pandoc-cite-pandoc-args-list
                           bib-args
                           `("-o" ,pandoc-outfile ,orig-outfile))) ;-o <OUTPUT FILE> <INPUT FILE>
         (pandoc-arg-list-str (mapconcat #'identity pandoc-arg-list " "))
         exit-code)
    (message (concat "[ox-hugo] Post-processing citations using Pandoc command:\n"
                     "  pandoc " pandoc-arg-list-str))

    (setq exit-code (apply 'call-process
                           (append
                            `("pandoc" nil
                              ,org-hugo-pandoc-cite--run-pandoc-buffer :display)
                            pandoc-arg-list)))

    (unless (= 0 exit-code)
      (user-error (format "[ox-hugo] Pandoc execution failed. See the %S buffer"
                          org-hugo-pandoc-cite--run-pandoc-buffer)))
    pandoc-outfile))

(defun org-hugo-pandoc-cite--remove-pandoc-meta-data (fm)
  "Remove Pandoc meta-data from front-matter string FM and return it.

The list of Pandoc specific meta-data is defined in
`org-hugo-pandoc-cite-pandoc-meta-data'."
  (with-temp-buffer
    (insert fm)
    (goto-char (point-min))
    (dolist (field org-hugo-pandoc-cite-pandoc-meta-data)
      (let ((regexp (format "^%s\\(:\\| =\\) " (regexp-quote field))))
        (delete-matching-lines regexp)))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun org-hugo-pandoc-cite--fix-pandoc-output (content loffset)
  "Fix the Pandoc output CONTENT and return it.

Required fixes:

- Unescape the Hugo shortcodes: \"{{\\\\=< shortcode \\\\=>}}\" ->
  \"{{< shortcode >}}\".

- Replace \"::: {#refs .references}\" with \"## References\"
  where the number of hashes depends on HUGO_LEVEL_OFFSET,
  followed by an opening HTML div tag.

- Replace \"::: {#ref-someref}\" with \"<div
  id=\"ref-someref\">\".

- Replace \"^:::$\" with closing HTML div tags.

LOFFSET is the offset added to the base level of 1 for headings."
  (with-temp-buffer
    (insert content)
    (let ((case-fold-search nil)
          (level-mark (make-string (+ loffset 1) ?#)))
      (goto-char (point-min))
      ;; Fix Hugo shortcodes.
      (save-excursion
        (let ((regexp (concat "{{\\\\<"
                              "\\(\\s-\\|\n\\)+"
                              "\\(?1:.+?\\)"
                              "\\(\\s-\\|\n\\)+"
                              "\\\\>}}")))
          (while (re-search-forward regexp nil :noerror)
            (replace-match "{{< \\1 >}}" :fixedcase))))
      ;; Convert Pandoc ref ID style to HTML div's.
      (save-excursion
        (let ((regexp "^::: {#ref-\\(.+?\\)}$"))
          (while (re-search-forward regexp nil :noerror)
            (replace-match (concat "<div id=\"ref-\\1\">"
                                   "\n  <div></div>\n") ;See footnote 1
                           :fixedcase)
            (re-search-forward "^:::$")
            (replace-match "\n</div>"))))
      ;; Replace "::: {#refs .references}" with a base-level
      ;; "References" heading in Markdown, followed by an opening HTML
      ;; div tag.
      (save-excursion
        (let ((regexp "^::: {#refs \\.references}$"))
          ;; There should be at max only one replacement needed for
          ;; this.
          (when (re-search-forward regexp nil :noerror)
            (replace-match (concat level-mark
                                   " References {#references}\n\n"
                                   "<div id=\"refs .references\">"
                                   "\n  <div></div>\n\n")) ;See footnote 1
            (re-search-forward "^:::$")
            (replace-match "\n\n</div> <!-- ending references -->"))))
      (buffer-substring-no-properties (point-min) (point-max)))))

(defun org-hugo-pandoc-cite--parse-citations-maybe (info)
  "Check if Pandoc needs to be run to parse citations; and run it.

INFO is a plist used as a communication channel."
  ;; (message "pandoc citations keyword: %S"
  ;;          (org-hugo--plist-get-true-p info :hugo-pandoc-citations))
  ;; (message "pandoc citations prop: %S"
  ;;          (org-entry-get nil "EXPORT_HUGO_PANDOC_CITATIONS" :inherit))
  (let* ((orig-outfile (plist-get info :outfile))
         (pandoc-enabled (or (org-entry-get nil "EXPORT_HUGO_PANDOC_CITATIONS" :inherit)
                             (org-hugo--plist-get-true-p info :hugo-pandoc-citations)))
         (fm (plist-get info :front-matter))
         (has-nocite (string-match-p "^nocite\\(:\\| =\\) " fm))
         (orig-outfile-contents (with-temp-buffer
                                  (insert-file-contents orig-outfile)
                                  (buffer-substring-no-properties
                                   (point-min) (point-max))))
         ;; http://pandoc.org/MANUAL.html#citations
         ;; Each citation must have a key, composed of `@' + the
         ;; citation identifier from the database, and may optionally
         ;; have a prefix, a locator, and a suffix. The citation key
         ;; must begin with a letter, digit, or _, and may contain
         ;; alphanumerics, _, and internal punctuation characters
         ;; (:.#$%&-+?<>~/).
         ;; A minus sign (-) before the @ will suppress mention of the
         ;; author in the citation.
         (valid-citation-key-char-regexp "a-zA-Z0-9_:.#$%&+?<>~/-")
         (citation-key-regexp (concat "[^" valid-citation-key-char-regexp "]"
                                      "\\(-?@[a-zA-Z0-9_]"
                                      "[" valid-citation-key-char-regexp "]+\\)"))
         (has-@ (string-match-p citation-key-regexp orig-outfile-contents)))
    (when pandoc-enabled
      ;; Either the nocite front-matter should be there, or the
      ;; citation keys should be present in the `orig-outfile'.
      (if (or has-nocite has-@)
          (progn
            (unless (executable-find "pandoc")
              (user-error "[ox-hugo] pandoc executable not found in PATH"))
            (org-hugo-pandoc-cite--parse-citations info orig-outfile))
        ;; Otherwise restore the front-matter format to TOML if set so
        ;; by the user.
        (unless (string= fm org-hugo--fm-yaml)
          (let* ((orig-contents-only
                  (replace-regexp-in-string
                   ;; The `orig-contents-only' will always be in YAML.
                   ;; Delete that first.
                   "\\`---\n\\(.\\|\n\\)+\n---\n" "" orig-outfile-contents))
                 (toml-fm-plus-orig-contents (concat fm orig-contents-only)))
            ;; (message "[ox-hugo-pandoc-cite] orig-contents-only: %S" orig-contents-only)
            (write-region toml-fm-plus-orig-contents nil orig-outfile)))))))

(defun org-hugo-pandoc-cite--parse-citations (info orig-outfile)
  "Parse Pandoc Citations in ORIG-OUTFILE and update that file.

INFO is a plist used as a communication channel.

ORIG-OUTFILE is the Org exported file name."
  (let ((bib-list (let ((bib-raw
                         (org-string-nw-p
                          (or (org-entry-get nil "EXPORT_BIBLIOGRAPHY" :inherit)
                              (org-export-data (plist-get info :bibliography) info))))) ;`org-export-data' required
                    (when bib-raw
                      ;; Multiple bibliographies can be comma or
                      ;; newline separated. The newline separated
                      ;; bibliographies work only for the
                      ;; #+bibliography keyword; example:
                      ;;
                      ;;   #+bibliography: bibliographies-1.bib
                      ;;   #+bibliography: bibliographies-2.bib
                      ;;
                      ;; If using the subtree properties they need to
                      ;; be comma-separated (now don't use commas in
                      ;; those file names, you will suffer):
                      ;;
                      ;;   :EXPORT_BIBLIOGRAPHY: bibliographies-1.bib, bibliographies-2.bib
                      (let ((bib-list-1 (org-split-string bib-raw "[,\n]")))
                        ;; - Don't allow spaces around bib names.
                        ;; - Convert file names to absolute paths.
                        ;; - Remove duplicate bibliographies.
                        (delete-dups
                         (mapcar (lambda (bib-file)
                                   (let ((fname (file-truename
                                                 (org-trim
                                                  bib-file))))
                                     (unless (file-exists-p fname)
                                       (user-error "[ox-hugo] Bibliography file %S does not exist"
                                                   fname))
                                     fname))
                                 bib-list-1)))))))
    (if bib-list
        (let ((fm (plist-get info :front-matter))
              (loffset (string-to-number
                        (or (org-entry-get nil "EXPORT_HUGO_LEVEL_OFFSET" :inherit)
                            (plist-get info :hugo-level-offset))))
              (pandoc-outfile (org-hugo-pandoc-cite--run-pandoc orig-outfile bib-list)))
          ;; (message "[ox-hugo parse citations] fm :: %S" fm)
          ;; (message "[ox-hugo parse citations] loffset :: %S" loffset)
          ;; (message "[ox-hugo parse citations] pandoc-outfile :: %S" pandoc-outfile)

          ;; Prepend the original ox-hugo generated front-matter to
          ;; Pandoc output.
          (let* ((fm (org-hugo-pandoc-cite--remove-pandoc-meta-data fm))
                 (pandoc-outfile-contents (with-temp-buffer
                                            (insert-file-contents pandoc-outfile)
                                            (buffer-substring-no-properties
                                             (point-min) (point-max))))
                 (contents-fixed (org-hugo-pandoc-cite--fix-pandoc-output
                                  pandoc-outfile-contents loffset))
                 (fm-plus-content (concat fm "\n" contents-fixed)))
            (write-region fm-plus-content nil orig-outfile)
            (delete-file pandoc-outfile))

          (with-current-buffer org-hugo-pandoc-cite--run-pandoc-buffer
            (if (> (point-max) 1)             ;buffer is not empty
                (message
                 (format
                  (concat "[ox-hugo] See the %S buffer for possible Pandoc warnings.\n"
                          "          Review the exported Markdown file for possible missing citations.")
                  org-hugo-pandoc-cite--run-pandoc-buffer))
              ;; Kill the Pandoc run buffer if it is empty.
              (kill-buffer org-hugo-pandoc-cite--run-pandoc-buffer))))
      (message "[ox-hugo] No bibliography file was specified"))))


(provide 'ox-hugo-pandoc-cite)



;;; Footnotes

;;;; Footnote 1
;; The empty HTML element tags like "<div></div>" is a hack to get
;; around a Blackfriday limitation.  Details:
;; https://github.com/kaushalmodi/ox-hugo/issues/93.


;;; ox-hugo-pandoc-cite.el ends here