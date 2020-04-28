;;; orderless.el --- Completion style for matching regexps in any order  -*- lexical-binding: t; -*-

;; Copyright (C) 2020  Omar Antolín Camarena

;; Author: Omar Antolín Camarena <omar@matem.unam.mx>
;; Keywords: extensions
;; Version: 0.4
;; Homepage: https://github.com/oantolin/orderless
;; Package-Requires: ((emacs "24.4"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This package provides an `orderless' completion style that divides
;; the pattern into components (space-separated by default), and
;; matches candidates that match all of the components in any order.

;; Completion styles are used as entries in the variables
;; `completion-styles' and `completion-category-overrides', see their
;; documentation.

;; To use this completion style you can use the following minimal
;; configuration:

;; (setq completion-styles '(orderless))

;; You can customize the `orderless-component-separator' to decide how
;; the input pattern is split into component regexps.  The default
;; splits on spaces.  You might want to add hyphens and slashes, for
;; example, to ease completion of symbols and file paths,
;; respectively.

;; Each component can match in any one of several matching styles:
;; literally, as a regexp, as an initialism, in the flex style, or as
;; word prefixes.  It is easy to add new styles: they are functions
;; from strings to strings that map a component to a regexp to match
;; against.  The variable `orderless-component-matching-styles' lists
;; the matching styles to be used for components, by default it allows
;; regexp and initialism matching.

;;; Code:

(require 'cl-lib)

(defgroup orderless nil
  "Completion method that matches space-separated regexps in any order."
  :group 'completion)

(defface orderless-match-face-0
  '((default :weight bold)
    (((class color) (min-colors 88) (background dark)) :foreground "#72a4ff")
    (((class color) (min-colors 88) (background light)) :foreground "#223fbf")
    (t :foreground "blue"))
  "Face for matches of components numbered 0 mod 4."
  :group 'orderless)

(defface orderless-match-face-1
  '((default :weight bold)
    (((class color) (min-colors 88) (background dark)) :foreground "#ed92f8")
    (((class color) (min-colors 88) (background light)) :foreground "#8f0075")
    (t :foreground "magenta"))
  "Face for matches of components numbered 1 mod 4."
  :group 'orderless)

(defface orderless-match-face-2
  '((default :weight bold)
    (((class color) (min-colors 88) (background dark)) :foreground "#90d800")
    (((class color) (min-colors 88) (background light)) :foreground "#145a00")
    (t :foreground "green"))
  "Face for matches of components numbered 2 mod 4."
  :group 'orderless)

(defface orderless-match-face-3
  '((default :weight bold)
    (((class color) (min-colors 88) (background dark)) :foreground "#f0ce43")
    (((class color) (min-colors 88) (background light)) :foreground "#804000")
    (t :foreground "yellow"))
  "Face for matches of components numbered 3 mod 4."
  :group 'orderless)

(defcustom orderless-component-separator " +"
  "Regexp to match component separators for orderless completion.
This is passed to `split-string' to divide the pattern into
component regexps."
  :type '(choice (const :tag "Spaces" " +")
                 (const :tag "Spaces, hyphen or slash" " +\\|[-/]")
                 (regexp :tag "Custom regexp"))
  :group 'orderless)

(defcustom orderless-match-faces
  [orderless-match-face-0
   orderless-match-face-1
   orderless-match-face-2
   orderless-match-face-3]
  "Vector of faces used (cyclically) for component matches."
  :type '(vector 'face)
  :group 'orderless)

(defcustom orderless-component-matching-styles
  '(orderless-regexp orderless-initialism)
  "List of default allowed component matching styles.
If this variable is nil, regexp matching is assumed.

A matching style is simply a function from strings to strings
that takes a component to a regexp to match against.  If the
resulting regexp has no capturing groups, the entire match is
highlighted, otherwise just the captured groups are.

This list provides the default matching styles for components
when the style dispatchers in `orderless-global-dispatchers'
decline to compute a list of default matching styles.  (Even if
those dispatchers do compute a list of matching styles, it is
only the default used for components, and can be overridden for
individual components by the style dispatchers in
`orderless-component-dispatchers')."
  :type '(set
          (const :tag "Regexp" orderless-regexp)
          (const :tag "Literal" orderless-literal)
          (const :tag "Initialism" orderless-initialism)
          (const :tag "Strict initialism" orderless-strict-initialism)
          (const :tag "Strict leading initialism"
            orderless-strict-leading-initialism)
          (const :tag "Strict full initialism"
            orderless-strict-full-initialism)
          (const :tag "Flex" orderless-flex)
          (const :tag "Prefixes" orderless-prefixes)
          (function :tag "Custom matching style"))
  :group 'orderless)

(defcustom orderless-component-dispatchers nil
  "List of style dispatchers for computing component matching styles.

The `orderless' completion style splits the input string into
components and for each component tries all style dispatchers
stored in this variable one at a time until one handles the
component.  If no dispatcher handles the component, default
matching styles are used for the component.

Those default matching styles are computed based on the entire
input string by `orderless-global-dispatchers' or, if no global
dispatcher handles the input string, the default styles are given
by `orderless-component-matching-styles'.

For details on the dispatch procedure see `orderless-dispatch'."
  :type 'hook
  :group 'orderless)

(defcustom orderless-global-dispatchers nil
  "List of style dispatchers for computing default matching styles.

This variable is used to compute default matching styles for
components based on the entire input string.  The dispatchers
stored in this variable are tried one at a time until one handles
the input sting.  If none do, the default matching styles are
instead given by `orderless-component-matching-styles'.

The matching styles computed as outlined above are only the
default styles to be used for each component, and can be
overridden on a component-by-component basis by
`orderless-component-dispatchers'.

For details on the dispatch procedure see `orderless-dispatch'."
  :type 'hook
  :group 'orderless)

(defcustom orderless-pattern-compiler #'orderless-default-pattern-compiler
  "The `orderless' pattern compiler.
This should be a function that takes an input pattern and returns
a list of regexps that must all match a candidate in order for
the candidate to be considered a completion of the pattern.

The default pattern compiler is probably flexible enough for most
users.  It splits the input on `orderless-component-separator',
computes default matching styles to use for all components by
running `orderless-global-dispatchers' (falling back on
`orderless-component-matching-styles'), and then computes
matching styles for individual components using
`orderless-style-dispatchers' (falling back on the global default
computed in the previous step).

The documentation for the following variables is written assuming
the default pattern compiler is used, if you change the pattern
compiler it can, of course, do anything and need not consult
these variables at all:

- `orderless-style-dispatchers'
- `orderless-global-dispatchers'
- `orderless-component-matching-styles'"
  :type 'function
  :group 'orderless)

;;; Matching styles

(defalias 'orderless-regexp #'identity
  "Match a component as a regexp.
This is simply the identity function.")

(defalias 'orderless-literal #'regexp-quote
  "Match a component as a literal string.
This is simply `regexp-quote'.")

(defun orderless--separated-by (sep rxs &optional before after)
  "Return a regexp to match the rx-regexps RXS with SEP in between.
If BEFORE is specified, add it to the beginning of the rx
sequence.  If AFTER is specified, add it to the end of the rx
sequence."
  (rx-to-string
   `(seq
     ,(or before "")
     ,@(cl-loop for (sexp . more) on rxs
                collect `(group ,sexp)
                when more collect sep)
     ,(or after ""))))

(defun orderless-flex (component)
  "Match a component in flex style.
This means the characters in COMPONENT must occur in the
candidate in that order, but not necessarily consecutively."
  (orderless--separated-by '(zero-or-more nonl)
   (cl-loop for char across component collect char)))

(defun orderless-initialism (component)
  "Match a component as an initialism.
This means the characters in COMPONENT must occur in the
candidate, in that order, at the beginning of words."
  (orderless--separated-by '(zero-or-more nonl)
   (cl-loop for char across component collect `(seq word-start ,char))))

(defun orderless--strict-*-initialism (component &optional start end)
  "Match a COMPONENT as a strict initialism, optionally anchored.
The characters in COMPONENT must occur in the candidate in that
order at the beginning of subsequent words comprised of letters.
Only non-letters can be in between the words that start with the
initials.

If START is non-nil, require that the first initial appear at the
first word of the candidate.  Similarly, if END is non-nil
require the last initial appear in the last word."
  (orderless--separated-by
   '(seq (zero-or-more word) word-end (zero-or-more (not alpha)))
   (cl-loop for char across component collect `(seq word-start ,char))
   (when start '(seq buffer-start (zero-or-more (not alpha))))
   (when end
     '(seq (zero-or-more word) word-end (zero-or-more (not alpha)) eol))))

(defun orderless-strict-initialism (component)
  "Match a COMPONENT as a strict initialism.
This means the characters in COMPONENT must occur in the
candidate in that order at the beginning of subsequent words
comprised of letters.  Only non-letters can be in between the
words that start with the initials."
  (orderless--strict-*-initialism component))

(defun orderless-strict-leading-initialism (component)
  "Match a COMPONENT as a strict initialism, anchored at start.
See `orderless-strict-initialism'.  Additionally require that the
first initial appear in the first word of the candidate."
  (orderless--strict-*-initialism component t))

(defun orderless-strict-full-initialism (component)
  "Match a COMPONENT as a strict initialism, anchored at both ends.
See `orderless-strict-initialism'.  Additionally require that the
first and last initials appear in the first and last words of the
candidate, respectively."
  (orderless--strict-*-initialism component t t))

(defun orderless-prefixes (component)
  "Match a component as multiple word prefixes.
The COMPONENT is split at word endings, and each piece must match
at a word boundary in the candidate.  This is similar to the
`partial-completion' completion style."
  (orderless--separated-by '(zero-or-more nonl)
   (cl-loop for prefix in (split-string component "\\>" t)
            collect `(seq word-boundary ,prefix))))

;;; Highlighting matches

(defun orderless--highlight (regexps string)
  "Propertize STRING to highlight a match of each of the REGEXPS.
Warning: only use this if you know all REGEXPs match!"
  (cl-loop with n = (length orderless-match-faces)
           for regexp in regexps and i from 0 do
           (string-match regexp string)
           (cl-loop
            for (x y) on (or (cddr (match-data)) (match-data)) by #'cddr
            when x do
            (font-lock-prepend-text-property
             x y
             'face (aref orderless-match-faces (mod i n))
             string)))
  string)

(defun orderless-highlight-matches (regexps strings)
    "Highlight a match of each of the REGEXPS in each of the STRINGS.
Warning: only use this if you know all REGEXPs match all STRINGS!
For the user's convenience, if REGEXPS is a string, it is
converted to a list of regexps according to the value of
`orderless-component-matching-styles'."
    (when (stringp regexps)
      (setq regexps (funcall orderless-pattern-compiler regexps)))
    (cl-loop for original in strings
             for string = (copy-sequence original)
             collect (orderless--highlight regexps string)))

;;; Compiling patterns to lists of regexps

(defun orderless-dispatch (dispatchers default string &rest args)
  "Run DISPATCHERS to compute matching styles for STRING.

A style dispatcher is a function that takes a string and possibly
some extra arguments.  It should either return (a) nil to
indicate the dispatcher will not handle the string, (b) a new
string to replace the current string and continue dispatch,
or (c) the matching styles to use and, if needed, a new string to
use in place of the current one (for example, a dispatcher can
decide which style to use based on a suffix of the string and
then it must also return the component stripped of the suffix).

More precisely, the return value of a style dispatcher can be of
one of the following forms:

- nil (to continue dispatching)

- a string (to replace the component and continue dispatching),

- a matching style or non-empty list of matching styles to
  return,

- a `cons' whose `car' is either as in the previous case or
  nil (to request returning the DEFAULT matching styles), and
  whose `cdr' is a string (to replace the current one).

This function tries all DISPATCHERS in sequence until one returns
a list of styles (passing any extra ARGS to every style
dispatcher).  When that happens it returns a `cons' of the list
of styles and the possibly updated STRING.  If none of the
DISPATCHERS returns a list of styles, the return value will use
DEFAULT as the list of styles."
  (cl-loop for dispatcher in dispatchers
           for result = (apply dispatcher string args)
           if (stringp result)
           do (setq string result result nil)
           else if (and (consp result) (null (car result)))
           do (setf (car result) default)
           else if (and (consp result) (stringp (cdr result)))
           do (setq string (cdr result) result (car result))
           when result return (cons result string)
           finally (return (cons default string))))

(defun orderless-default-pattern-compiler (pattern)
  "Build regexps to match the components of PATTERN.

Split PATTERN on `orderless-component-separator' and compute
matching styles for each component.  The matching styles are
computed using `orderless-component-dispatchers' and default to
the value computed using `orderless-global-dispatchers', which in
turn defaults to `orderless-component-matching-styles'.  See
`orderless-dispatch' for details on how the lists of dispatchers
are used.

This is the default value of `orderless-pattern-compiler'."
  (cl-loop
   with (default . newpat) = (orderless-dispatch
                              orderless-global-dispatchers
                              (or orderless-component-matching-styles
                                  'orderless-regexp)
                              pattern)
   with components = (split-string newpat orderless-component-separator)
   with total = (length components)
   for component in components and index from 0
   for (styles . newcomp) = (orderless-dispatch
                             orderless-component-dispatchers
                             default component index total)
   collect
   (if (functionp styles)
       (funcall styles newcomp)
     (rx-to-string
      `(or
        ,@(cl-loop for style in styles
                   collect `(regexp ,(funcall style newcomp))))))))

;;; Completion style implementation

(defun orderless--prefix+pattern (string table pred)
  "Split STRING into prefix and pattern according to TABLE.
The predicate PRED is used to constrain the entries in TABLE."
  (let ((limit (car (completion-boundaries string table pred ""))))
    (cons (substring string 0 limit) (substring string limit))))

;;;###autoload
(defun orderless-filter (string table &optional pred)
  "Split STRING into components and find entries TABLE matching all.
The predicate PRED is used to constrain the entries in TABLE."
  (condition-case nil
      (save-match-data
        (pcase-let* ((`(,prefix . ,pattern)
                      (orderless--prefix+pattern string table pred))
                     (completion-regexp-list
                      (funcall orderless-pattern-compiler pattern)))
          (all-completions prefix table pred)))
    (invalid-regexp nil)))

;;;###autoload
(defun orderless-all-completions (string table pred _point)
  "Split STRING into components and find entries TABLE matching all.
The predicate PRED is used to constrain the entries in TABLE.  The
matching portions of each candidate are highlighted.
This function is part of the `orderless' completion style."
  (let ((completions (orderless-filter string table pred)))
    (when completions
      (pcase-let ((`(,prefix . ,pattern)
                   (orderless--prefix+pattern string table pred)))
        (nconc
         (orderless-highlight-matches pattern completions)
         (length prefix))))))

;;;###autoload
(defun orderless-try-completion (string table pred point &optional _metadata)
  "Complete STRING to unique matching entry in TABLE.
This uses `orderless-all-completions' to find matches for STRING
in TABLE among entries satisfying PRED.  If there is only one
match, it completes to that match.  If there are no matches, it
returns nil.  In any other case it \"completes\" STRING to
itself, without moving POINT.
This function is part of the `orderless' completion style."
  (let ((all (orderless-filter string table pred)))
    (cond
     ((null all) nil)
     ((null (cdr all))
      (let ((full (concat
                   (car (orderless--prefix+pattern string table pred))
                   (car all))))
        (cons full (length full))))
     (t (cons string point)))))

;;;###autoload
(add-to-list 'completion-styles-alist
             '(orderless
               orderless-try-completion orderless-all-completions
               "Completion of multiple components, in any order."))

;;; Temporary separator change (does anyone use this?)

(defvar orderless-old-component-separator nil
  "Stores the old value of `orderless-component-separator'.")

(defun orderless--restore-component-separator ()
  "Restore old value of `orderless-component-separator'."
  (when orderless-old-component-separator
    (setq orderless-component-separator orderless-old-component-separator
          orderless-old-component-separator nil))
  (remove-hook 'minibuffer-exit-hook #'orderless--restore-component-separator))

(defun orderless-temporarily-change-separator (separator)
  "Use SEPARATOR to split the input for the current completion session."
  (interactive
   (list (let ((enable-recursive-minibuffers t))
           (read-string "Orderless regexp separator: "))))
  (unless orderless-old-component-separator
    (setq orderless-old-component-separator orderless-component-separator))
  (setq orderless-component-separator separator)
  (add-to-list 'minibuffer-exit-hook #'orderless--restore-component-separator))

;;; Ivy integration

(defvar ivy-regex)
(defvar ivy-highlight-functions-alist)

;;;###autoload
(defun orderless-ivy-re-builder (str)
  "Convert STR into regexps for use with ivy.
This function is for integration of orderless with ivy, use it as
a value in `ivy-re-builders-alist'."
  (or (mapcar (lambda (x) (cons x t))
              (funcall orderless-pattern-compiler str))
      ""))

(defun orderless-ivy-highlight (str)
  "Highlight a match in STR of each regexp in `ivy-regex'.
This function is for integration of orderless with ivy."
  (orderless--highlight (mapcar #'car ivy-regex) str) str)

;;;###autoload
(with-eval-after-load 'ivy
  (add-to-list 'ivy-highlight-functions-alist
               '(orderless-ivy-re-builder . orderless-ivy-highlight)))

(provide 'orderless)
;;; orderless.el ends here
