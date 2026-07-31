# Changelog

Notable changes, following [Keep a Changelog](https://keepachangelog.com/).

## Unreleased

### Added

- Completion via 'omnifunc' (`<C-x><C-o>`): invocation targets after
  `exec.`/`call.`/`syscall.`/`procref.` (local procs, imported symbols,
  module qualifiers, and a module's procs after `mod::`), constants after
  `push.`, and opcodes/keywords at instruction position -- all from the same
  index navigation uses. Procedure candidates show their
  `[inputs] -> [outputs]` doc contract in the menu, opcodes their stack
  effect.
- Project-wide rename (`grn` / `:MasmRename`): renames the definition,
  references that spell the definition-site name and the original side of
  importing/re-exporting `use { orig as alias }` items, while alias
  spellings survive. Edits are verified against buffer content, applied
  bottom-up and left unsaved for review.
- Optional debugger integration with nvim-dap: a `miden` adapter that
  attaches to a running Miden DAP server or launches
  `miden-debug --start-debug-adapter` / `miden-client exec
  --start-debug-adapter` with free-port fallback and readiness detection,
  plus `:MasmDapState` showing the VM cycle, operand stack and call stack
  from the `miden/uiState` event. Inert without nvim-dap; opt out with
  `vim.g.masm_no_dap`.
- Order-aware stack comment checking (`comment-reordered`): a `# => [...]`
  comment listing exactly the simulated stack's named elements in a
  different order is flagged -- the swapped-operands documentation bug that
  width checking cannot see. Renamed or anonymous elements can never trip
  it.
- Dialect-drift canary (`unrecognized-import`): `use` statements matching
  none of the resolver's known forms are published as diagnostics, so a
  future dialect change degrades loudly instead of silently.
- `begin..end` entrypoint blocks are analyzed: they enter on the 16-element
  physical stack (declared `#! Inputs:` named and zero-padded), trackers
  and branches are checked like any procedure, and a program ending deeper
  than 16 is an error (the VM caps stack outputs at 16).

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

### Changed

- The references scan runs time-sliced on the event loop instead of
  blocking the UI thread; the quickfix list opens on completion, and a new
  scan cancels the one in flight. `references({ sync = true })` keeps the
  blocking behavior and returns the items.
- References and rename scans read the live text of every loaded buffer,
  not just the current one, so unsaved edits elsewhere are seen.

### Fixed

- `gd` on the `exec`/`call` keyword of a qualified invocation
  (`exec.math::add`) jumped to the module file instead of the invoked
  procedure; the retargeted token now resolves its final segment.
- Single-colon paths (`math:add`) resolved as if they were `::`; they are
  now rejected -- the assembler rejects them too.
- A launch-setup failure in the nvim-dap adapter left the session start
  suspended (the callback was never invoked); it now resumes nvim-dap with
  an abort.
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
