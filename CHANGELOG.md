# Changelog

Notable changes, following [Keep a Changelog](https://keepachangelog.com/).

## Unreleased

### Added

- Completion via 'omnifunc' (`<C-x><C-o>`): invocation targets after
  `exec.`/`call.`/`syscall.`/`procref.`, constants after `push.`, and
  opcodes/keywords at instruction position. Procedure candidates show their
  `[inputs] -> [outputs]` doc contract, opcodes their stack effect.
- Project-wide rename (`grn` / `:MasmRename`): renames the definition,
  references that spell the definition-site name, and the original side of
  `use { orig as alias }` items; alias spellings survive. Edits are verified
  against buffer content, applied bottom-up and left unsaved for review. A
  new name that already means something in any file the rename would touch
  is refused -- a silent symbol merge is never applied.
- Optional nvim-dap integration: a `miden` adapter that attaches to a
  running Miden DAP server or launches `miden-debug` / `miden-client exec`
  with free-port fallback and readiness detection, plus `:MasmDapState`
  showing the VM cycle, operand stack and call stack. Concurrent sessions
  each keep their own backend and VM state. Inert without nvim-dap; opt out
  with `vim.g.masm_no_dap`.
- Static stack analysis: a per-instruction operand-stack simulator publishes
  errors for exits that would trip the VM's `InvalidStackDepthOnReturn` and
  for 16-element call-ABI violations, warnings when handwritten `# => [...]`
  comments disagree with the simulation (width and order), and analyzes
  `begin..end` entrypoints. `:MasmStackToggle` overlays the inferred stack
  as ghost text. Procedures that cannot be analyzed are skipped with a
  stated reason, never guessed at. Configure via `vim.g.masm_stack`;
  disable entirely with `vim.g.masm_no_stack`.
- `K` hover: the definition's doc comment, attributes and signature
  (resolved exactly like `gd`), module doc blocks on qualifiers, and the
  bundled instruction reference for bare opcodes (hand-maintained entries
  fill the gaps in the generated masm-lsp snapshot; a consistency test
  keeps reference, arity table and highlights in agreement).
- Dialect-drift canary: `use` statements matching none of the resolver's
  known forms are published as diagnostics, so a future dialect change
  degrades loudly instead of silently.
- The project index refreshes automatically when a new `.masm` file or a
  `miden-project.toml` is saved; `:MasmRebuildIndex` covers deletions,
  moves and out-of-editor changes.
- Locals query captures (`@local.definition.*` / `@local.reference`) for
  locals-aware consumers.
- Test and CI hardening: a dedicated suite for the security/robustness
  defenses (bounded file reads, walk limits, manifest path containment,
  scan cancellation, simulator budgets); luacheck, StyLua and
  lua-language-server at zero problems (tools version- and
  checksum-pinned); query validation on the v0.10.4 floor; a macOS leg;
  a non-blocking nightly leg; and a reproducible benchmark
  (`scripts/bench.lua`) that fails on a known cache-regression signature.

### Changed

- The references scan runs time-sliced off the UI thread; a new scan
  cancels the one in flight, and a scan whose source buffers were edited
  mid-flight redoes itself instead of publishing mixed pre/post-edit
  positions. References and rename read every loaded buffer's live text.
- Stack-analysis refreshes are an order of magnitude cheaper: one
  comment/string-blanking pass per refresh, per-procedure memoization keyed
  on the exact source slice plus signatures of every cross-file lookup, and
  a changedtick early-out on the debounced path. Warm results are
  bit-identical to a cold pass; the cross-procedure `callee-unresolved`
  hint is deduplicated at publish time, keeping each procedure's cached
  result independent of pass order.
- Internal restructuring: `masm.goto` is now a facade over `masm.project`
  (index walk, manifest parsing) and `masm.resolve` (imports, symbol
  resolution), with shared helpers in `masm.util` -- one `$`-inclusive
  identifier charset, hardened file access, size-capped caches. Public
  surfaces carry LuaCATS annotations. Every documented entry point is
  unchanged.
- Debug backend lifecycle: backends are tracked per DAP port (a session's
  end kills only its own), killed on `VimLeavePre`, terminated with SIGTERM
  escalating to SIGKILL after a grace period, and never EPIPE-killed by
  post-handshake logging. Captured output is per-session, byte-capped and
  retained for a bounded number of ended sessions.
- `:checkhealth masm` is a pure inspection: it reports adapter state
  instead of registering as a side effect.
- The analyzer refuses what the assembler refuses instead of simulating it
  wrongly: out-of-range positional indices (`movup.99`), index immediates
  on bare-form ops (`swapdw.3`), bodies sharing the declaration line, and
  unterminated procedures (WARN `missing-end`, and the procedures below
  keep analyzing).

### Fixed

- The stack analyzer's cross-file contract and constant lookups are
  live-buffer-wins, exactly like resolution: an unsaved edit to a callee's
  `#! Inputs:/Outputs:` contract (or to a constant it pushes) is seen by
  callers immediately, and an unsaved edit that shifts a callee's lines can
  no longer produce a false "no procedure declaration" hint. Completion's
  `[inputs] -> [outputs]` summaries read the same live text.
- Paths are canonicalized (symlinks resolved) everywhere they are compared:
  index roots, caller-passed buffer paths and BufWritePost invalidation.
  Two spellings of one file (macOS `/var` vs `/private/var`, a symlinked
  project directory) can no longer defeat live-buffer-wins resolution or
  index auto-refresh.
- MASM path splitting accepts only exact `::` separators: `a:b`, `a::::b`
  and edge-colon spellings are refused everywhere (navigation, completion,
  imports), matching the assembler.
- Rename: bare instruction tokens are never treated as references to
  same-named procedures (renaming `add` no longer rewrites opcodes);
  `$`-sigil identifiers work through selective imports, rename and
  completion; a definition that moved during an async prompt aborts the
  rename; `shortmess+=A` is restored on every path.
- Resolution: re-export chain results are freshness-keyed on every file
  consulted, so editing a middle hop re-resolves immediately; modified
  non-current buffers are read live; buffer lookups match names exactly
  (no `bufnr()` pattern surprises); the cross-file lookup budget counts
  distinct targets, so repeated constants cannot starve later diagnostics.
- Stack analysis: `caller-underflow` no longer fires on states the
  analyzer itself declared unknowable, and the `# => [...]` resync its
  hint recommends actually recovers; a `DiagnosticChanged` handler that
  edits the buffer mid-publish cannot pin stale diagnostics; invalid
  `vim.g.masm_stack` / `vim.g.masm_goto` fields degrade loudly to their
  defaults, named per field; failure notices latch per message, so a new
  kind of failure is never swallowed by an earlier one.
- DAP: two near-simultaneous launches can no longer tear each other down
  (a new launch never reuses a live backend's port key); ending an attach
  session spares a launch backend on the same port; a launch-setup failure
  resumes nvim-dap instead of leaving the session start suspended forever.
- Activation: `.masm` filetype registration on Neovim 0.10 (built-in
  detection ships with 0.11), and a version-floor guard that disables the
  plugin with one clear message on older builds.
- Matching: `_` and `$` are identifier characters everywhere, so `gd` on
  `add` cannot land on `proc add_checked` and `gO` cannot list `begin_foo`
  as an entrypoint; hover boundary off-by-ones fixed; completion offers
  `exp.u`; a library directory literally named `foo..bar` is no longer
  refused by the manifest containment check.

## 0.1.0 - 2026-07-23

Initial release: tree-sitter highlighting/indent/folds/textobjects for the
pinned [tree-sitter-masm](https://github.com/0xMiden/tree-sitter-masm)
grammar, and text-based project-aware navigation (`gd`/`<C-]>` via
'tagfunc', `grr` references through renamed re-exports, `gO` document
symbols, `:MasmRebuildIndex`, `:checkhealth masm`).
