# Changelog

Notable changes, following [Keep a Changelog](https://keepachangelog.com/).

## Unreleased

### Added

- Static stack analysis: a per-instruction operand-stack simulator publishes
  `vim.diagnostic` errors when a `call`-invoked procedure would return at a
  stack depth other than the mandatory 16 (the VM rejects every such call at
  runtime with `InvalidStackDepthOnReturn`), when a declared
  `Inputs:/Outputs:` contract violates the 16-element call ABI, and warnings
  when handwritten `# => [...]` stack comments disagree with the simulation.
  `:MasmStackToggle` shows an inferred-stack ghost-text overlay on lines
  without handwritten annotations. Configured via `vim.g.masm_stack`;
  disabled entirely with `vim.g.masm_no_stack`. Cross-procedure effects come
  from the callees' declared stack contracts through the existing project
  index; procedures that cannot be analyzed are skipped with a stated
  reason, never guessed at.
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
