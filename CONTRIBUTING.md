# Contributing to miden-masm.nvim

Thanks for considering a contribution. This document covers the layout, how
to run the tests, and the conventions the code follows.

## Development setup

Clone the repo and load it as a local plugin. With lazy.nvim:

```lua
{ dir = "~/path/to/miden-masm.nvim", lazy = false },
```

Open any `.masm` file to exercise the ftplugin and navigation. Run
`:checkhealth masm` to confirm the environment.

## Running the tests

```
make test          # navigation test suite (no network needed)
make test-queries  # builds the pinned grammar, validates the queries
make lint          # luacheck static analysis (config in .luacheckrc)
make check         # lua-language-server type check (config in .luarc.json)
make fmt           # stylua, rewriting in place (CI runs --check and fails)
```

`make test` runs nine suites headlessly (`nvim --headless --clean`):
`tests/masm_test.lua` (navigation, references sync and async, rename
including opcode-named procs and collision refusal, index auto-refresh,
re-export chain invalidation, config surface, resolver limits, the
dialect-drift canary), `tests/hover_test.lua` (content and the float
layer), `tests/stack_test.lua` (stack-list notation, instruction arities,
the stack simulator including order-aware comment checking, one-line-body
and immediate-range bails, and its UI incl. the autocmd pipeline) and
`tests/complete_test.lua` (omnifunc contexts) against the fixture project
in `tests/fixtures/`, which is a miniature Miden workspace -- two
namespaced libraries, a renamed re-export chain, a kernel library, a
single-file account component and an adversarial fixture;
`tests/fixtures/app/stack.masm` ports the real min_burn_amount depth-17
bug as a regression pair -- plus `tests/dap_test.lua` (launch argv, port
fallback, the spawn/readiness protocol and pipe draining against stub
processes; per-port child tracking; nvim-dap registration against a stub
module), `tests/health_test.lua` (`:checkhealth masm` against stubbed
reporters, including that the check never mutates state),
`tests/consistency_test.lua` (the arity table, instruction reference and
highlight keyword list must agree -- see below),
`tests/ftplugin_test.lua` for filetype detection and the ftplugin's
setup/teardown, and `tests/hardening_test.lua` for the security/robustness
defenses (`util.read_file`'s size/type refusals, the index walk's symlink,
depth and entry-cap bounds, `miden-project.toml` path containment,
references-scan cancellation and the stack simulator's budgets). No Miden
checkout, Miden binaries or network access are needed, and each suite exits
non-zero on failure. Suites never touch the tracked fixtures on disk:
`masm_test.lua` copies `tests/fixtures/` into a temp directory and runs
against the copy, `hardening_test.lua` builds all of its fixtures in temp
directories, and both delete them in teardown -- keep new tests to that
standard, and build them on `tests/helpers.lua` (the shared `check()`,
fixture-anchored `placer()` and exit-epilogue plumbing every suite loads)
instead of re-rolling that boilerplate.

`make test-queries` clones and compiles the pinned tree-sitter-masm revision
(network + C compiler required), then asserts each query in `queries/masm/`
both parses and produces captures on the fixtures - an impossible pattern
(wrong node or field name) parses fine but matches nothing, which is exactly
the regression this catches.

If you change resolution behavior, add a fixture case. Prefer extending the
existing fixture files over adding new ones, and keep each case's cursor
placement anchored on a `find` string rather than hard-coded line numbers so
fixtures can evolve.

## Layout

- `lua/masm/util.lua` - shared low-level helpers, free of project/index
  knowledge by design: the canonical `$`-inclusive identifier charset
  (`IDENT_CHARS` and friends -- every identifier pattern must be built from
  it), MASM path splitting, memoized comment/string blanking
  (`code_only`/`code_text`), the byte-offset line tracker, hardened bounded
  file access (`read_file`, `stat_key` freshness keys) and the bounded
  cache plumbing (full clear on overflow).
- `lua/masm/project.lua` - the project index: root discovery (git root or
  outermost `miden-project.toml`), the bounded directory walk with its
  traversal defenses (symlink skip, depth and entry caps, manifest `path`
  containment), manifest parsing and the per-index lookup caches.
- `lua/masm/resolve.lua` - use-statement parsing (all import forms, on raw
  text) and symbol resolution: local, imported, qualified and kernel
  targets, `pub use` re-export chains (depth-capped, cycle-checked), plus
  the dialect-drift canary's unrecognized-import scan. Resolution is
  deliberately text-based; see the header comment before reaching for
  tree-sitter here.
- `lua/masm/scan.lua` - the narrow cooperative project-file scanner shared
  by quickfix producers: time slicing, cancellation, live-buffer reads and
  bounded changedtick-based stale-result retries.
- `lua/masm/goto.lua` - the public navigation facade over `masm.project`
  and `masm.resolve`: cursor context, tagfunc, references, rename, document
  symbols, and every documented entry point
  (`resolve()`, `make_resolver()`, the import/interface queries other
  modules build on).
- `lua/masm/complete.lua` - 'omnifunc' completion: context detection plus
  candidate enumeration through goto's index and the instruction reference.
- `lua/masm/dap.lua` - optional nvim-dap integration: launch argv
  construction, port allocation, backend spawn/readiness, `miden/uiState`
  capture and `:MasmDapState`. Inert without nvim-dap.
- `lua/masm/hover.lua` - `K` hover: definition-site doc blocks via the
  resolver, instruction docs via the generated reference.
- `lua/masm/stack.lua` - the stack-analysis engine: procedure segmentation,
  per-instruction operand-stack simulation, contract cache, checks, and the
  per-procedure memoization (a warm result must be bit-identical to a cold
  pass). UI-free; reasons travel in the result, never through `vim.notify`.
- `lua/masm/stacknotation.lua` - shared parser for the stack-list notation
  used by `#! Inputs:/Outputs:` contracts and `# => [...]` comments.
- `lua/masm/arity.lua` - HAND-AUDITED instruction arities. Not generated:
  the prose stack effects in `instructions.lua` carry arity errors. Add new
  instructions here AND to the corpus vocabulary list in
  `tests/stack_test.lua`; `tests/consistency_test.lua` will then insist the
  instruction reference and the highlight keyword list know them too (fill
  reference gaps in `instructions_extra.lua`).
- `lua/masm/stackview.lua` - stack-analysis UI: diagnostics publishing,
  ghost-text overlay, project-wide comment quickfix, debounce, attach/detach.
- `lua/masm/instructions.lua` - GENERATED instruction metadata; do not edit.
  Regenerate with `scripts/gen_instructions.py` against a
  [masm-lsp](https://github.com/trailofbits/masm-lsp) checkout when Miden
  adds or changes instructions. Hand-written entries for mnemonics the
  metadata lacks go in `lua/masm/instructions_extra.lua`, which the
  generated file appends at load time (regeneration cannot lose them);
  `tests/consistency_test.lua` flags entries that become redundant.
- `lua/masm/health.lua` - `:checkhealth masm`.
- `after/ftplugin/masm.lua` - buffer-local settings, keymaps, commands. In
  `after/` because it corrects Neovim's built-in `masm` (Microsoft
  assembler) ftplugin.
- `plugin/miden-masm.lua` - registers `*.masm` filetype detection (Neovim
  0.10 lacks the built-in mapping) and the parser with nvim-treesitter via
  the `User TSUpdate` autocmd. Do not "simplify" the latter into a one-off
  assignment; nvim-treesitter rebuilds its parser table on install/update
  and would silently discard it.
- `queries/masm/*.scm` - queries ported from the grammar's Zed-oriented
  bundle to Neovim's conventions.
- `tests/helpers.lua` - shared suite plumbing: the runtimepath preamble,
  `check()`, the fixture-anchored `placer()` and the uniform "ALL PASS"
  exit epilogue. Every suite loads it via `dofile`; suites still run one
  Neovim process each, so no fixture or cache state crosses suites.

## Porting queries

The upstream grammar bundles queries written for Zed. When updating them:

- Zed's `@indent`/`@end` become Neovim's `@indent.begin`/`@indent.end`.
- Zed's textobject captures use `.inside`/`.around`; Neovim uses
  `.inner`/`.outer`.
- `@comment.doc` becomes `@comment.documentation`, `@parameter` becomes
  `@variable.parameter`.
- Run `make test-queries` before committing (CI runs it too); an impossible
  pattern (wrong field name) parses the file it is in but never matches,
  which is exactly what the captures assertion catches.

If you bump the pinned grammar revision in `plugin/miden-masm.lua`, re-check
every query against the new node names and update the revision note in the
query headers.

## Style

- Lua is formatted with [StyLua](https://github.com/JohnnyMorganz/StyLua)
  using the repo's `.stylua.toml` (2-space indent, 100 columns). `make fmt`
  rewrites in place with the same pinned version CI checks against
  (`--check` there, so an unformatted file fails the build).
- `make lint` must pass:
  [luacheck](https://github.com/lunarmodules/luacheck) with the repo's
  `.luacheckrc` catches unused locals, accidental globals and shadowing.
  Install it via your package manager, `luarocks install luacheck`, or the
  standalone binary from the luacheck releases page (CI pins v1.2.0).
  Prefix a deliberately unused local or argument with `_` instead of adding
  inline disables.
- `make check` must pass:
  [lua-language-server](https://github.com/LuaLS/lua-language-server)'s
  `--check` at zero problems, with the repo's `.luarc.json` (the vim API
  type definitions come from `$VIMRUNTIME/lua`, derived from your installed
  nvim; CI pins the checker at v3.15.0 and Neovim at v0.12.4, and an older
  local runtime can report noise CI does not count). Fix findings with real
  annotation or control-flow improvements (`---@param`/`---@return`,
  `---@cast`, an early normalize, a restructured guard); a per-line
  `---@diagnostic disable-next-line` with a stated reason is a last resort
  for places the checker is genuinely wrong (the tests' deliberate
  stubbing of `vim.notify` and friends).
- Comments explain constraints the code cannot show (why an approach is
  required), not what the next line does.
- Error paths report a reason to the user (`vim.notify`) rather than
  failing silently.

## Reporting resolution bugs

The most useful bug report contains:

- a minimal `.masm` snippet (plus `miden-project.toml` if the project layout
  matters),
- the cursor position, and
- where the jump should have landed vs. where it did (or the reason message
  shown).

If it can be expressed as a fixture case, even better: a failing test in
`tests/masm_test.lua` is the fastest path to a fix.

## Commits and releases

Use [Conventional Commit](https://www.conventionalcommits.org/) prefixes.
`feat:` produces a minor release, `fix:` produces a patch release, and a
`!` suffix or `BREAKING CHANGE:` footer marks a breaking release. While the
project is below 1.0, breaking changes bump the minor version rather than
declaring 1.0 automatically. The existing Gitmoji after the prefix is fine;
for example, `fix(stack): 🐛 reject an invalid immediate` is parsed as a fix.

Release Please runs after pushes to `main` and maintains one release PR. That
PR updates `version.txt`, `.release-please-manifest.json`, and `CHANGELOG.md`.
Merge it when the accumulated changes are ready to publish; the following
workflow run creates the `vX.Y.Z` tag and GitHub release. Do not edit the two
version files by hand.

For the initial automated `1.0.0` release only, reconcile the hand-written
`Unreleased` section already in `CHANGELOG.md` with the generated entry before
merging. Releases after that are generated entirely from commit messages.

The workflow can use the built-in `GITHUB_TOKEN`, provided the repository's
Actions settings allow GitHub Actions to create pull requests. To also run the
normal pull-request workflows when the release PR is opened or updated, add a
fine-grained `RELEASE_PLEASE_TOKEN` repository secret with Contents,
Pull requests, and Issues read/write access; events created with the built-in
token do not start further workflow runs.
