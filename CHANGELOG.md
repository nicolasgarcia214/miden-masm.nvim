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
- Hardening test suite (`tests/hardening_test.lua`): assertions on the
  security/robustness defenses -- `util.read_file`'s size cap, FIFO and
  non-regular-file refusals; the index walk's symlinked-directory skip,
  depth cap and entry cap (via a `_max_scan_entries` test hook);
  `miden-project.toml` `path` containment (absolute paths, `..` components
  and symlink-escaping components are all refused); references-scan
  in-flight cancellation and sync preemption (via a `_scan_slice_ms` test
  hook); and the stack simulator's instruction and cell-window budgets.
  All fixtures are built in temp directories and removed in teardown.
- CI hardening: static analysis with luacheck (`make lint`, config in
  `.luacheckrc`) over `lua/`, `plugin/`, `after/` and `tests/`; the query
  validation job now also runs on the advertised v0.10.4 floor, whose older
  treesitter query parser could reject constructs stable accepts; and a
  helptags check that fails the build if `doc/` stops generating tags
  cleanly. Lint fixes: two accidental writes to a global `_` (in
  `lua/masm/dap.lua` and a test) are now proper discards, plus a shadowed
  file-handle local and a dead test variable -- no behavior changes.

- Reproducible benchmark (`scripts/bench.lua`, run with
  `nvim --headless --clean -l scripts/bench.lua <project-root>`): measures
  the cold index-plus-references scan, a warm references scan, warmed-up
  resolution and stack analysis of the largest file, through the plugin's
  public API. The README's performance numbers are now what this script
  measures (Miden protocol monorepo: ~165 indexed files / ~33k lines,
  references ~260 ms cold / ~200 ms warm, resolution ~0.3 ms, stack
  analysis of a ~2k-line file ~8 ms cold / ~2 ms warm). The script is
  luacheck'd with the rest of the tree.
- `make fmt`: rewrites formatting in place with the same pinned StyLua CI
  checks against -- the local fix-it counterpart to the CI job's `--check`.
- CI: a macOS leg (stable Neovim) in the test matrix -- the codebase is
  POSIX-pathed, so this catches BSD-userland and case-insensitive-filesystem
  drift -- and the nightly leg is now non-blocking (`continue-on-error`):
  upstream Neovim breakage surfaces in the checks UI without blocking
  merges. Dependabot keeps the SHA-pinned workflow actions' digests moving
  (`.github/dependabot.yml`, weekly).
- README states the supported platforms explicitly: Linux and macOS
  (CI-covered); Windows untested and unsupported (path handling is POSIX).
- The stackview lifecycle API is documented in `:h miden-masm-api`:
  `masm.stackview.attach()`/`refresh()`/`detach()`, plus
  `masm.stack.analyze()` and `masm.goto.clear_cache()` -- so users who set
  `g:masm_no_stack` have a supported per-buffer opt-in path (the
  `g:masm_no_stack` entry points at it).

### Changed

- `stacknotation.comment_part` uses the same plain-find fast-path/segment
  technique as `util.code_only` instead of a per-byte state machine (it
  runs on every line of every analyzed proc per refresh). Behavior is
  identical: verified by a differential test of old vs new over every
  corpus line plus adversarial cases (`#` in strings, escaped quotes,
  `#!`, trailing trackers) and a 50k-case fuzz -- 83,488 cases, zero
  mismatches -- with the edge cases pinned in the suite.
- `stackview.refresh` reads the buffer once and passes the lines through
  to the analysis, the drift canary and the overlay (previously each read
  its own copy); per-refresh/per-line `require()` calls are hoisted to
  file-top locals like every other module. `apply_special`'s unreachable
  `else return false` fallthrough is removed (the only caller dispatches
  on `arity.special`, and every base in that table has a branch).
- The test suites share `tests/helpers.lua` (runtimepath preamble,
  `check()`, `place()`, exit epilogue) instead of nine copy-pasted
  variants; every suite -- stack_test included, which had its own
  "stack tests: all passed" spelling -- now ends with the uniform
  "ALL PASS" sentinel. Suites keep full process isolation (one Neovim per
  suite; the helpers hold nothing but the loading process's failure
  counter). The shared `place()` errors on a missing locator instead of
  returning false silently -- which is what exposed the vacuous rename
  assertion above.
- CI: one concurrency group per ref (a superseded push cancels the run it
  obsoleted), and the queries job caches the grammar clone+build keyed on
  the pinned revision's source of truth (`plugin/miden-masm.lua`), with
  `actions/cache` SHA-pinned like every other action in the file. The
  cache key also carries the compiler version (`cc -dumpversion`, captured
  in a step output since `hashFiles` cannot run commands): the cached
  artifact is a compiled `.so`, and a runner-image toolchain bump must
  rebuild it, not restore an object the new toolchain never produced.
- Symbol resolution's file-interface cache hits no longer walk the entire
  buffer list to find the buffer serving a file (7.9x warm-resolution
  slowdown with ~200 unrelated buffers open; 8.1x per hit): each cache
  entry remembers the buffer it last saw -- or that there was none -- and
  revalidates that cheaply (validity/name/modified checks; an exact-name
  `bufexists()` for "none", sound because Neovim forbids two buffers
  sharing a name), falling back to the full walk only when the answer
  changed. Semantics are unchanged -- a modified loaded buffer still wins
  (changedtick key), a clean or absent one still tracks disk (stat key) --
  and now pinned directly by a {clean, modified} x {disk unchanged, disk
  changed} test matrix plus reverted-buffer and buffer-appears-later
  cases. `scripts/bench.lua` asserts the regression class away
  mechanically: it fails (nonzero exit) if a warm file-interface hit
  slows more than a deliberately generous 3x with ~200 scratch buffers
  open (healthy: ~1.3x; the regression signature: ~8x).
- Annotation coverage for the thin modules (stackview, complete, health)
  is brought up to resolve.lua's density on public surfaces (`@class`es
  for the view config/state and completion items, `@param`/`@return` on
  the helpers) -- and the codebase now passes `lua-language-server
  --check` at ZERO problems. A first evaluation had punted on the job
  (~31 strict-mode findings looked like unavoidable noise); they are
  fixed for real now: the nil/0 bufnr normalization idiom became a typed
  `util.norm_bufnr` helper, the fallible libuv allocations in `masm.dap`
  (`new_tcp`/`new_pipe`/`new_timer`) gained genuine fd-exhaustion guards
  that report instead of crashing on a nil handle,
  `stacknotation.expand` declares the structural `{elems}` parameter it
  actually reads, `scripts/bench.lua` bails with a reason on an
  unreadable corpus, and the tests `assert()` their fallible setups. A
  handful of reasoned per-line disables remain only where the checker is
  genuinely wrong (the tests' deliberate stubbing of `vim.notify` and
  friends trips `duplicate-set-field` by design). Enforced by a new CI
  job that pins both verdict inputs -- the checker (v3.15.0,
  checksum-verified release tarball) and the Neovim runtime providing
  the vim type definitions (v0.12.4) -- and runnable locally as
  `make check` (config in `.luarc.json`; documented in CONTRIBUTING).
- `tests/masm_test.lua` runs against a temp copy of `tests/fixtures/`
  instead of the tracked tree. The suite's fixture-mutating blocks
  (stale-cache padding, re-export chain retargeting, created-then-removed
  files) restored the originals under pcall, but a hard crash (kill -9,
  OOM) would have defeated the restore and left the checkout dirty; now the
  tracked fixtures are only ever read, and a crash can at worst leak a temp
  directory. The hardening suite's two fixed 300 ms `vim.wait` pumps (which
  a loaded CI box could starve past, passing vacuously) are now condition
  polls with a generous hard-bounded timeout.
- Stack-analysis refreshes are an order of magnitude cheaper. The buffer is
  comment/string-blanked once per pass (previously three to four times, one
  character at a time), unqualified definition lookups use a memoized
  name-to-line map instead of rescanning the whole buffer per lookup, and
  each procedure's analysis is memoized on its exact source slice plus
  signatures of every cross-procedure answer it consumed (callee contracts,
  constant widths) -- so a typical edit re-simulates only the touched
  procedure while results stay bit-identical to a cold pass, including
  lookup-budget accounting and cross-procedure hint deduplication. The
  debounced refresh path also skips entirely when `b:changedtick` has not
  moved since the last publish (an insert-mode round trip without an edit);
  explicit refreshes (writes, `:MasmStackToggle`) always run. Measured on a
  556 KB concatenated corpus buffer: ~560 ms per refresh before, ~20-26 ms
  for an edit-and-refresh and ~15 ms for a no-op refresh after; cold
  analysis ~80 ms.
- Internal restructuring: `masm.goto` is now a facade over two new modules
  -- `masm.project` (project index: directory walk, `miden-project.toml`
  parsing, per-index caches) and `masm.resolve` (use-statement parsing,
  symbol resolution, re-export chains) -- and the cross-module helpers that
  used to ride on `masm.goto`'s underscore exports (bounded file reads,
  freshness keys, comment/string blanking, exact-name buffer lookup, path
  splitting) live in `masm.util`. Every documented entry point, mapping and
  command is unchanged; `masm.goto._file_written` remains for the
  BufWritePost index-invalidation hook.
- The identifier charset is defined once (`masm.util`, `$`-inclusive as the
  grammar allows) and shared by cursor scanning, definition matching,
  document symbols and the stack analyzer, which previously disagreed on
  whether `$` may appear in a name.
- Public functions and the shared data shapes (project index, tag items,
  simulator states, analyzer results) carry LuaCATS annotations.
- The resolution, project-index and analyzer contract caches are size-capped
  (generous caps, full clear on overflow) so a pathological session cannot
  grow them without bound.
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

- Index roots and explicit buffer paths are canonicalized (symlinks
  resolved) before use, matching how Neovim spells buffer names. Paths
  reaching one file through two spellings -- macOS's `/var` vs
  `/private/var` temp directory is the everyday case, and it broke the
  macOS CI leg -- no longer defeat the exact-name buffer matching that
  live-buffer-wins resolution relies on.
- `references()`/rename read the definition line with the same
  live-buffer-wins semantics as resolution. A definition file left modified
  in a non-current buffer (the post-rename, unsaved-for-review state)
  previously had its definition line read from disk while the line NUMBER
  came from the live buffer, silently failing the scan.
- Two near-simultaneous debug launches can no longer tear each other down:
  a new launch never reuses a port that is already a live backend's key
  (binding used to succeed in the window before the first backend bound its
  socket, and the second launch then killed the first's process).
- Ending an `attach` debug session no longer kills a launch session's
  backend listening on the same port; only launch sessions own their
  backend process.
- The stack-analysis debounce records the changedtick captured with the
  analyzed buffer lines, so a `DiagnosticChanged` autocmd that edits the
  buffer mid-publish cannot pin stale diagnostics; the debounce early-out
  also re-checks `vim.g.masm_stack`, so config changes apply without
  needing an edit or write.
- Warm symbol resolution stays cheap after `:bdelete` of a dependency file:
  the cached "no buffer for this path" answer revalidates with
  `bufloaded()` instead of `bufexists()`, which kept forcing the full
  buffer walk the cache exists to avoid.
- A `use` statement with trailing junk is no longer half-accepted: the
  import parser and the dialect-drift canary now share one set of anchored
  patterns, so such a line is refused as an import and reported as drift
  instead of being imported *and* flagged.
- Backend output retained for debug-launch diagnostics is capped by bytes
  (64 KB per session key) instead of by chunk count, bounding worst-case
  memory held for chatty backends.
- `make test-queries` rebuilds the vendored grammar when the pinned
  revision in `plugin/miden-masm.lua` changes, instead of validating
  queries against a stale build.
- `caller-underflow` no longer fires on poisoned states: cells drawn from
  the caller while the state is poisoned (e.g. after an exec of an
  undocumented callee) are phantom cells from a suffix the analyzer
  declared unknowable, not draws against the declared Inputs, so they no
  longer count toward the tally -- previously the warning fired on such
  states and the `# => [...]` resync its own hint recommended could not
  clear it (the tracker reset the poison but not the tally). The exit
  check also gained the same poisoned guard its exec-net sibling already
  had. Genuine (unpoisoned) draws beyond the declared Inputs still warn.
- The cross-file lookup budget (`MAX_LOOKUPS`) counts DISTINCT
  callee/constant targets, as its comment always claimed, instead of every
  raw lookup: repeated `push.CONST`s of one constant are cache hits that
  cost nothing, and under total counting a file with ~40 procs pushing the
  same constants exhausted the budget so that a genuine depth-17
  `exit-depth` ERROR later in the file silently degraded to a poison and a
  hidden hint. The memo's dep replay mirrors the distinct accounting
  exactly, keeping warm results bit-identical to a cold pass (regression
  corpus: unchanged, 164 files / 852 procs / 21 warn+error / 72 hints).
- Navigation follows a just-applied rename while its edits sit unsaved for
  review: symbol resolution's file-interface parse now reads a MODIFIED
  loaded buffer (freshness-keyed on its changedtick) instead of the stale
  disk copy; clean buffers keep reading from disk, so out-of-editor edits
  still track. The suite's "navigation follows the new name" assertion
  turned out to pass vacuously before (its cursor placement reloaded the
  buffer from disk, discarding the very rename it asserted on); it is now
  a real assertion.
- Invalid `vim.g.masm_stack` / `vim.g.masm_goto` fields degrade loudly to
  their defaults with a one-time, field-naming notification instead of
  silently misbehaving: `overlay_mode = true` used to disable the "auto"
  gating quietly, `debounce_ms = "300"` worked only through luv's implicit
  coercion, and a mistyped `extra_roots`/`ignore_dirs` (anything other
  than a string or list of strings) silently narrowed resolution.
- README and vimdoc Limitations now state the poison/consumed trade the
  analyzer's source always documented: elements genuinely consumed from
  the caller before a later instruction poisons the state go unreported
  as caller-underflow unless a `# => [...]` resync clears the unknown
  state before the procedure ends (never-warn-on-unknowable wins over
  reporting the tally).
- README: the DAP launch-key list now includes `midenDebugPath`,
  `midenClientPath` and `runtime` (dap.lua and the vimdoc always had
  them), and the references-scan claim states the real bound: the slice
  deadline is checked between files, so a single enormous file is still
  scanned in one uninterrupted slice (vimdoc aligned too).
- A procedure missing its `end` no longer swallows everything below it: the
  next `proc`/`begin` declaration ends it as unterminated, every following
  procedure keeps analyzing (previously the whole rest of the file lost its
  diagnostics silently while typing a new proc above existing code), and
  the unterminated procedure itself gets a WARN diagnostic (`missing-end`)
  -- an end-less proc is a syntax error the assembler rejects, so the
  warning cannot false-positive on valid code.
- `swapdw`, `reversew` and `reversedw` with an index immediate
  (`swapdw.3`) were silently accepted; the instruction reference documents
  them in bare form only, so they now bail the procedure with a stated
  reason, exactly like `movup.99`.
- `$`-sigil identifiers now work through selective imports
  (`use { $name } from ..`), import-item rename and completion of
  buffer-local constants; those scanners still used a `$`-less identifier
  charset despite `masm.util` defining the canonical `$`-inclusive one.
- The debug backends spawned for launch configurations are killed on
  `VimLeavePre`, so quitting Neovim mid-session no longer orphans
  `miden-debug`/`miden-client` processes when nvim-dap emits no
  terminated/exited/disconnect event.
- `:MasmRebuildIndex` now also drops the content-keyed memos (doc-contract
  parses, definition maps, blanked buffer text), matching its documented
  "drop the cached project index and resolution caches" behavior; the
  memos could never serve stale data, but the command now does exactly
  what the docs say.
- `masm.dap` derived its own `vim.uv or vim.loop` alias instead of using
  `masm.util`'s shared one.
- The unreachable `emit` shortcut in the simulator was removed; `emit`'s
  stack effect now comes from the arity table like every table-driven
  instruction, leaving one source of truth (behavior is unchanged: net 0
  in both forms).
- On Neovim older than the supported 0.10.4 floor the plugin now disables
  itself with one clear message instead of loading and failing later with
  an obscure error.
- Completion after a qualified path used a lax splitter that accepted
  single-colon paths (`a:b::`) the assembler rejects; it now uses the same
  strict splitter as navigation and offers nothing for malformed paths.
- A rename that errored mid-application could leave `shortmess+=A` set for
  the rest of the session; the flag is restored on every path now.
- `masm.stackview.refresh(nil)` silently did nothing while
  `attach`/`toggle`/`detach` treated nil as the current buffer; all four
  normalize consistently now.
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
- Backend output captured for debug-adapter error reports is now keyed per
  session (by the same port key as the child processes): with concurrent
  debug sessions, launching the second wiped the first's captured output --
  exactly the evidence needed when a launch fails -- and both backends
  interleaved writes into one shared buffer.

## 0.1.0 - 2026-07-23

Initial release: tree-sitter highlighting/indent/folds/textobjects for the
pinned [tree-sitter-masm](https://github.com/0xMiden/tree-sitter-masm)
grammar, and text-based project-aware navigation (`gd`/`<C-]>` via
'tagfunc', `grr` references through renamed re-exports, `gO` document
symbols, `:MasmRebuildIndex`, `:checkhealth masm`).
