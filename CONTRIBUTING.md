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
```

`make test` runs `tests/masm_test.lua` headlessly (`nvim --headless -u NONE`)
against the fixture project in `tests/fixtures/`, which is a miniature Miden
workspace: two namespaced libraries, a renamed re-export chain, a kernel
library, a single-file account component and an adversarial fixture. No Miden
checkout or network access is needed, and the suite exits non-zero on
failure.

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

- `lua/masm/goto.lua` - all navigation: project index, import parsing,
  symbol resolution, tagfunc, references, document symbols. Resolution is
  deliberately text-based; see the header comment before reaching for
  tree-sitter here.
- `lua/masm/hover.lua` - `K` hover: definition-site doc blocks via the
  resolver, instruction docs via the generated reference.
- `lua/masm/instructions.lua` - GENERATED instruction metadata; do not edit.
  Regenerate with `scripts/gen_instructions.py` against a
  [masm-lsp](https://github.com/trailofbits/masm-lsp) checkout when Miden
  adds or changes instructions.
- `lua/masm/health.lua` - `:checkhealth masm`.
- `after/ftplugin/masm.lua` - buffer-local settings, keymaps, commands. In
  `after/` because it corrects Neovim's built-in `masm` (Microsoft
  assembler) ftplugin.
- `plugin/miden-masm.lua` - registers the parser with nvim-treesitter via
  the `User TSUpdate` autocmd. Do not "simplify" this into a one-off
  assignment; nvim-treesitter rebuilds its parser table on install/update
  and would silently discard it.
- `queries/masm/*.scm` - queries ported from the grammar's Zed-oriented
  bundle to Neovim's conventions.

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
  using the repo's `.stylua.toml` (2-space indent, 100 columns).
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
