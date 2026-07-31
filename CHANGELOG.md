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
- Order-aware stack comment checking (`comment-reordered`): a `# => [...]`
  comment listing exactly the simulated stack's named elements in a
  different order is flagged -- the swapped-operands documentation bug that
  width checking cannot see. Renamed or anonymous elements can never trip
  it.
- `begin..end` entrypoint blocks are analyzed: they enter on the 16-element
  physical stack (declared `#! Inputs:` named and zero-padded), trackers
  and branches are checked like any procedure, and a program ending deeper
  than 16 is an error (the VM caps stack outputs at 16).
- Dialect-drift canary (`unrecognized-import`): `use` statements matching
  none of the resolver's known forms are published as diagnostics, so a
  future dialect change degrades loudly instead of silently.
- `K` hover documentation: the definition's `#!` doc comment, `@` attributes
  and signature (resolved exactly like `gd`, so renamed imports and
  re-exports work), module doc blocks on qualifiers, and description plus
  stack effect for bare opcodes from the bundled Miden instruction
  reference. A second `K` focuses the float.
- The project index refreshes automatically when a new `.masm` file or a
  `miden-project.toml` is saved from Neovim; `:MasmRebuildIndex` is only
  needed for deletions, moves and out-of-editor changes.
- Rename refuses a new name already defined in the definition's file
  (renaming onto it would silently merge the two symbols), and re-verifies
  the definition before applying when the name came from an asynchronous
  `vim.ui.input` prompt (the target is captured at prompt time, so a moved
  cursor cannot redirect the rename).
- Locals query (`queries/masm/locals.scm`) now carries
  `@local.definition.*` and `@local.reference` captures (procedure,
  constant and type names; invocation paths and constant immediates) in
  addition to the upstream scopes, so locals-aware consumers have something
  to act on.
- Hand-maintained instruction reference entries
  (`lua/masm/instructions_extra.lua`) for mnemonics the generated masm-lsp
  snapshot lacks (`eqz`, `nop`, `breakpoint`, `adv_pushw`, `reversew`,
  `reversedw`, plain `mem_loadw`/`mem_storew`/`loc_loadw`/`loc_storew`,
  and the `u32widening_*` family), so hover and completion know every
  instruction the stack analyzer simulates; a consistency test keeps the
  arity table, instruction reference and highlight keyword list in
  agreement from now on.

### Changed

- The references scan runs time-sliced on the event loop instead of
  blocking the UI thread; the quickfix list opens on completion, and a new
  scan cancels the one in flight. `references({ sync = true })` keeps the
  blocking behavior and returns the items.
- References and rename scans read the live text of every loaded buffer,
  not just the current one, so unsaved edits elsewhere are seen.
- Concurrent debug sessions: each launch's backend is tracked by its DAP
  port, a session's end kills only its own backend, and backend
  stdout/stderr stay drained for the process's lifetime (closing them at
  the readiness handshake could kill Rust backends with an EPIPE panic on
  their first post-handshake log line).
- `:checkhealth masm` is now a pure inspection: it reports whether the DAP
  adapter is registered instead of registering it as a side effect.
- The stack analyzer refuses (with a stated reason) positional indices the
  assembler rejects (`movup.99`) and procedures whose body tokens share
  the declaration line, instead of simulating them wrongly; one-line
  procedures no longer steal the following procedure's `end` during
  scanning. Diagnostics sort deterministically on ties.

### Fixed

- References and rename no longer treat bare instruction tokens as
  references to same-named procedures: with a proc named after an opcode
  (Miden's `std::math::u64` defines `add`, `and`, `eq`), rename rewrote
  the instruction tokens themselves, silently corrupting the program. Bare
  names now count only in symbol positions (after invocation/immediate
  dots, `=`, declaration keywords, inside `use { .. }` lists, on
  attribute lines and in `const`/`type` expressions).
- Re-export chain resolutions are freshness-keyed on every file the lookup
  consulted, so retargeting a `pub use` in the middle of a chain (or
  adding a definition an earlier search missed) re-resolves immediately
  instead of serving the cached destination until `:MasmRebuildIndex`.
- Hover: the cursor sitting on the dot of an unresolvable dotted operand
  no longer shows the mnemonic family's docs (off-by-one in the
  mnemonic-boundary check), and definitions open modified in another
  buffer hover their live text instead of the stale disk state.
- Completion: `exp.u{n}` was silently dropped from opcode candidates (the
  template collapse required a dot before the placeholder); it is offered
  as `exp.u` now.
- Scans look buffers up by exact name instead of `bufnr()`'s file-name
  pattern matching, which could mismatch paths containing `[`, `*` or `,`.
- `:tag`-style tagfunc calls wrap resolution in `pcall` like the cursor
  path, so an internal error reports instead of escaping into the tag
  machinery; rename guards `bufload` against swap-file prompts; a library
  directory literally named `foo..bar` is no longer refused by the
  manifest path-traversal check (components are checked, not substrings).
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
