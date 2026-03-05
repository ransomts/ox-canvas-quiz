# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`ox-canvas-quiz` is a single-file Emacs Lisp package (`ox-canvas-quiz.el`) that implements an Org mode export backend. It converts Org quiz files into the [text2qti](https://github.com/gpoore/text2qti) `.md` format, which can then be converted to QTI `.zip` files for import into Canvas LMS.

## Usage

**Interactive (from Emacs):**
- `C-c C-e Q q` — Export quiz to `.md`
- `C-c C-e Q z` — Export quiz to `.zip` via text2qti
- `C-c C-e Q b` — Export question bank to `.md`
- `C-c C-e Q B` — Export question bank to `.zip` via text2qti

**Batch:**
```sh
emacs --batch FILE.org -l ox-canvas-quiz.el -f org-canvas-quiz-export-to-md-batch
emacs --batch FILE.org -l ox-canvas-quiz.el -f org-canvas-quiz-export-to-qti-batch
emacs --batch FILE.org -l ox-canvas-quiz.el -f org-canvas-quiz-export-to-bank-md-batch
emacs --batch FILE.org -l ox-canvas-quiz.el -f org-canvas-quiz-export-to-bank-qti-batch
```

The `.zip` export requires the `text2qti` CLI tool in PATH.

## Architecture

The export pipeline is a linear transformation: **Org parse tree → question plists → text2qti markdown string**.

1. **Parsing** (`org-element-parse-buffer`): Standard Org parser produces the element tree.
2. **Collection** (`org-canvas-quiz--collect-questions`): Walks level-2 headlines, skipping `:noexport:` tags and specific level-1 sections ("Short Answer Questions", "Review Questions"). Produces a list of question plists with `:type`, `:text`, `:options`/`:answers`, `:feedback`, `:points`, `:title`.
3. **Type detection** (`org-canvas-quiz--question-type`): Checks `:Type:` property first (Numerical, ShortAnswer, Essay, Upload), then falls back to checkbox counting (1 correct = MC, 2+ = MA).
4. **Formatting**: Two output paths diverge here:
   - `org-canvas-quiz--format-output` (quiz): MC questions without custom points go into a `GROUP` block for random selection; everything else is standalone. Uses `Quiz Title:`.
   - `org-canvas-quiz--format-bank-output` (question bank): All questions are standalone (no GROUP, no shuffle). Uses `Question Bank Title:`.

## Org File Conventions

- **Level-1 headlines**: Section groupings (only "Short Answer Questions" and "Review Questions" are skipped)
- **Level-2 headlines**: Individual questions (headline text becomes `Title:`)
- **Properties drawer**: `:Type:`, `:Answer:`, `:Tolerance:`, `:Points:`, `:Feedback:`, `:CorrectFeedback:`, `:IncorrectFeedback:`
- **Checkbox lists**: MC/MA answer options; `[X]` = correct, `[ ]` = incorrect
- **Plain lists (no checkboxes)**: Accepted answers for Short Answer type
- **Per-answer feedback**: Append `Feedback: text` after the answer text within a list item

## Supported Question Types

| Type | Detection | text2qti marker |
|---|---|---|
| Multiple Choice | 1 checked box, or no `:Type:` with 1 `[X]` | `*b)` prefix |
| Multiple Answers | 2+ checked boxes | `[*]` / `[ ]` |
| Numerical | `:Type: Numerical` | `= val +- tol` |
| Short Answer | `:Type: ShortAnswer` | `* accepted` |
| Essay | `:Type: Essay` | `____` |
| File Upload | `:Type: Upload` | `^^^^` |

## Key Design Details

- `#+QUIZ_SHUFFLE: yes` adds `shuffle answers: true` to output
- Markup interpretation (`org-canvas-quiz--interpret-object`) converts Org inline elements to plain text with backtick code spans; LaTeX fragments pass through as-is
- Multi-paragraph questions use indented continuation lines in the output
- The `00-demo-all-question-types.org` file serves as both documentation and a test fixture covering all question types and features
