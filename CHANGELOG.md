# Changelog

Notable changes, following [Keep a Changelog](https://keepachangelog.com/).

## Unreleased

### Added

- `K` hover documentation: the definition's `#!` doc comment, `@` attributes
  and signature (resolved exactly like `gd`, so renamed imports and
  re-exports work), module doc blocks on qualifiers, and description plus
  stack effect for bare opcodes from the bundled Miden instruction
  reference. A second `K` focuses the float.

### Fixed

- `.masm` files were left with filetype `conf` on Neovim 0.10 (built-in
  `*.masm` detection only ships with 0.11), so none of the plugin activated;
  the plugin now registers the filetype mapping itself.
- Definition matching treated `_` as a word boundary (Lua's `%W` excludes
  it), so `gd` on a bare `add` token could jump to `proc add_checked`; the
  same off-by-a-class frontier affected `use`/`mod` statement matching and
  let `gO` list a `begin_foo` line as the program entrypoint.

## 0.1.0 - 2026-07-23

Initial release: tree-sitter highlighting/indent/folds/textobjects for the
pinned [tree-sitter-masm](https://github.com/0xMiden/tree-sitter-masm)
grammar, and text-based project-aware navigation (`gd`/`<C-]>` via
'tagfunc', `grr` references through renamed re-exports, `gO` document
symbols, `:MasmRebuildIndex`, `:checkhealth masm`).
