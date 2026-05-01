# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### Added

- Added hover previews for referenced equations under `\ref`, `\eqref`, `\autoref`, `\cref`, `\Cref`, `\vref`, and `\Vref`.
- Added hover previews for citation commands such as `\cite`, `\citet`, `\citep`, `\parencite`, and `\textcite`, resolving entries from local `.bib` files.
- Added runtime toggles for referenced-equation previews:
  - `:LatexPreview refs`
  - `:LatexPreview refs-on`
  - `:LatexPreview refs-off`
- Added runtime toggles for citation previews:
  - `:LatexPreview cites`
  - `:LatexPreview cites-on`
  - `:LatexPreview cites-off`
- Added default toggle keymaps when `setup_keymap = true`:
  - `<leader>ir` toggles referenced-equation previews.
  - `<leader>ic` toggles citation previews.
- Added `references` and `citations` configuration sections.

### Changed

- Display equations now use LaTeX display style by default via `render.display_math_style = "display"`.
- Physical source line breaks inside display equations are treated as spaces unless the equation uses an explicit multiline math environment such as `align`, `aligned`, `gather`, or `multline`.
- Render cache version was bumped so older cached images do not preserve previous newline behavior.
- Hover targeting now checks, in order: math under cursor, supported reference command, supported citation command.

### Fixed

- Fixed Treesitter math-environment handling so `\begin{...}...\end{...}` wrappers are stripped before sending equations to MathJax.
- Fixed escaped `$` parsing by counting consecutive preceding backslashes.
- Fixed `%` comment stripping by counting consecutive preceding backslashes.
- Fixed numeric buffer cache cleanup by clearing parse and preamble caches on `BufWipeout`.
- Fixed popup placement near the bottom/right edge by accounting for popup dimensions.
- Avoided mutating current hover state before a pending render succeeds.
- Avoided deleting cached render files from hover cleanup paths.
- Added cleanup for stale temporary render directories.
- Added warnings when `render.pad_to_cells = true` but ImageMagick is unavailable.
- Improved `:checkhealth latex-preview` detection for nvm-managed global `mathjax-full`.
- Made daemon command resolution respect later `setup({ daemon = { cmd = ... } })` changes.
- Narrowed Snacks document-render autocmd removal to avoid deleting unrelated future `snacks.image` FileType handlers.

### Documentation

- Updated README and Vim help with reference/citation preview usage, toggles, keymaps, and limitations.
- Documented display-style rendering and source newline behavior.
