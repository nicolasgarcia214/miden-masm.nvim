# miden-masm.nvim

Neovim support for [Miden Assembly](https://0xmiden.github.io/miden-docs/) (`.masm`):
tree-sitter highlighting plus project-aware code navigation, hover docs and
static stack analysis, with no language server required.

## Features

- Syntax highlighting, indentation, folds, locals and textobjects via the
  official [tree-sitter-masm](https://github.com/0xMiden/tree-sitter-masm)
  grammar, with queries hand-ported to Neovim's capture conventions.
- Go to definition (`gd` / `<C-]>`) for procedures, constants, types and
  modules, across library boundaries.
- Hover docs (`K`): the `#!` doc comment, `@` attributes and signature of the
  definition under the cursor -- the `Inputs:/Outputs:` stack contracts Miden
  code documents are readable at the call site without jumping. On a bare
  opcode, its description and stack effect from the Miden instruction
  reference (e.g. `u32overflowing_add`:
  `(b, a, ...) → (overflow, (a + b) mod 2^32, ...)`).
- Find references (`grr`) into the quickfix list, resolving every candidate
  usage to its ground-truth definition, so renamed re-exports are unified
  correctly.
- Document symbols (`gO`) into the location list.
- Stack analysis: a per-instruction operand-stack simulator that catches the
  bug class the VM only rejects at runtime -- a `call`-invoked procedure not
  returning at stack depth exactly 16 (`InvalidStackDepthOnReturn`). In the
  Miden protocol repo this class shipped more than once: a getter whose
  cleanup drops 3 elements where 4 are needed aborts on *every* invocation,
  and no test catches it. The analyzer flags it as you type, verifies the
  handwritten `# => [...]` stack comments against the simulation (the buggy
  getter's comment is flagged one line before the faulty cleanup), checks
  declared `Inputs:/Outputs:` contracts against the 16-element call ABI, and
  offers an inferred-stack ghost-text overlay (`:MasmStackToggle`) showing
  `# => [VALUE, pad(16)]`-style state on lines that have no handwritten
  annotation.
- Correct comment settings (`#` / `#!`), 4-space indentation, and matchit
  words for Miden's `proc`/`begin`/`if.true`/`while.true` ... `end` blocks
  (Neovim's built-in `masm` filetype targets Microsoft Macro Assembler and
  gets all of these wrong for Miden; on Neovim 0.10, which does not detect
  `.masm` files at all, the plugin registers the filetype itself).

Navigation is text-based and works out of the box; only highlighting,
indentation and folds need the tree-sitter parser.

## Requirements

- Neovim 0.10.4+
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)
  (main branch) and a C compiler, for the optional parser

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "nicolasgarcia214/miden-masm.nvim",
  lazy = false,
},
{
  "nvim-treesitter/nvim-treesitter",
  branch = "main",
  build = ":TSUpdate",
},
```

The plugin registers the `masm` parser with nvim-treesitter at startup; run
`:TSInstall masm` once to compile and install it. The revision is pinned to
the exact grammar the bundled queries were ported against.

Once the parser is installed, highlighting, indentation and folds turn on
automatically in `.masm` buffers - the plugin's ftplugin calls
`vim.treesitter.start()` and sets `indentexpr`/`foldexpr` itself, because
nvim-treesitter's main branch deliberately enables nothing on its own. Set
`vim.g.masm_no_treesitter = true` if you manage those settings yourself.

On [LazyVim](https://www.lazyvim.org/) (which wraps nvim-treesitter and adds
an `ensure_installed` option upstream does not have), you can install the
parser automatically instead:

```lua
{
  "nvim-treesitter/nvim-treesitter",
  opts = function(_, opts)
    table.insert(opts.ensure_installed, "masm")
  end,
},
```

Verify the setup with `:checkhealth masm`.

## Usage

All mappings are buffer-local to `.masm` files:

- `gd` or `<C-]>` - go to the definition of the name under the cursor. On a
  module qualifier (the `math` in `exec.math::add_checked`), on a `use` path
  segment, or on a `pub mod` name, this opens the module's file instead.
  `<C-t>` jumps back (the whole tag stack works, including `:tag`,
  `:tjump` and friends).
- `K` - hover documentation for the name under the cursor: the definition's
  doc comment, attributes and signature (resolved exactly like `gd`, so
  renamed imports and re-exports work), or the instruction reference entry
  for a bare opcode. Press `K` again to focus the float; `q` or moving the
  cursor closes it.
- `grr` - find references project-wide, into the quickfix list with the
  definition first. On a module qualifier or `use` path it lists every
  `use` statement importing that module.
- `gO` - list the buffer's definitions (procs, consts, types, submodules,
  entrypoint) in the location list.
- `:MasmRebuildIndex` - drop the cached project index (see below).
- `:MasmStackToggle` - toggle the inferred-stack ghost-text overlay for this
  buffer. Stack diagnostics are on by default and refresh on `InsertLeave`,
  normal-mode edits (debounced) and every write; they render through your
  normal `vim.diagnostic` configuration under the source name `masm-stack`.

## How name resolution works

The resolver mirrors the Miden assembler's project model:

- `miden-project.toml` files define libraries: `[lib] namespace` maps a
  module path prefix to a directory, so `fix::core::math` resolves to
  `<root>/math.masm` (or `math/mod.masm`). Account components are single-file
  libraries named after their directory; the library with `kind = "kernel"`
  is what `syscall.` targets resolve against.
- Within a file, `use` statements are parsed in all their forms: plain module
  imports, `as` renames, and selective `use { a, b as c } from path` imports
  (including multi-line ones).
- `pub use` re-export chains are followed to the underlying definition, with
  renames tracked at every hop. References apply the same resolution to every
  candidate usage in the project, which is how a call site spelling a
  constant `MAX_AMOUNT` and another spelling it `FUNGIBLE_ASSET_MAX_AMOUNT`
  both count as references to the same definition.
- The index roots at your git root (or the outermost `miden-project.toml`),
  skipping `target/`, `node_modules/` and hidden directories, and is cached
  per session.

On a large real-world project (the Miden protocol monorepo, ~180 files,
~37k lines) a cold references scan takes ~250 ms and a warm one ~180 ms;
go-to-definition is ~1 ms after the first jump.

## Configuration

Optional, via `vim.g.masm_goto` (set it before the first jump, or run
`:MasmRebuildIndex` after changing it):

```lua
vim.g.masm_goto = {
  -- Extra directories scanned for miden-project.toml libraries. Point this
  -- at a miden-vm checkout to resolve `std::..` / `miden::core::..`, whose
  -- sources are not part of downstream projects.
  extra_roots = { "~/work/miden-vm" },

  -- Directory names never descended into while indexing (replaces the
  -- default list).
  ignore_dirs = { "target", "node_modules" },
}

-- Set this to define your own keymaps instead of the default gd/grr/gO/K
-- (call require("masm.goto").references() / .document_symbols() and
-- require("masm.hover").hover() directly; 'tagfunc' stays active either
-- way, so <C-]> and :tag keep working).
vim.g.masm_no_default_mappings = true

-- Set this if you wire up vim.treesitter.start()/indentexpr/foldexpr
-- yourself (LazyVim users do not need it; double-starting is harmless).
vim.g.masm_no_treesitter = true

-- Stack analysis. All fields optional; these are the defaults.
vim.g.masm_stack = {
  diagnostics = true, -- publish stack diagnostics via vim.diagnostic
  overlay = false, -- start new buffers with the ghost-text overlay on
  overlay_mode = "auto", -- "auto": ghost only unannotated/stale lines; "all"
  check_comments = true, -- verify handwritten `# => [...]` comments (WARN)
  bail_hints = false, -- HINT diagnostics on procedures that cannot be analyzed
  debounce_ms = 300, -- delay after edits before re-analysis
}

-- Set this to disable stack analysis entirely (no autocmds, no command).
vim.g.masm_no_stack = true
```

Both list options also accept a single string as a one-element list.

## Limitations

Honest list, so you know what you are getting:

- The pinned tree-sitter grammar predates the current MASM dialect: it does
  not know `use { .. } from ..`, `pub mod`, or `use .. as ..`, so those
  import headers parse as ERROR nodes (in the Miden protocol repo that is
  ~1.4% of lines, essentially all in file headers; `mod.masm` files, being
  lists of `pub mod` lines, parse entirely as errors). Procedure bodies
  highlight fine. This is also exactly why navigation is text-based instead
  of tree-sitter-based: the resolver must understand the statements the
  grammar cannot.
- Navigation is resolution by convention, not by executing the assembler:
  it does not model conditional compilation, shadowing, or dialect corners
  the regexes do not cover. Unresolvable names report a reason (e.g. which
  module was not found) rather than guessing.
- `std::` / `miden::core::` targets need `extra_roots` (see above), since
  those sources ship with miden-vm, not with user projects.
- References scan files on disk (plus the current buffer's unsaved text);
  other modified-but-unsaved buffers are read from disk. In particular, if
  the definition itself lives in another unsaved buffer, references are
  computed against its on-disk line numbers until it is saved.
- Re-export chains are followed up to 5 hops; deeper chains report "not
  found". Cyclic chains are detected and fail cleanly. Retargeting a
  `pub use` line in the middle of a 3+ hop chain can keep serving the old
  destination for already-resolved names until `:MasmRebuildIndex`.
- The index walk and references scan are synchronous. The quoted timings are
  for a ~180-file project; a large `extra_roots` (a full miden-vm checkout)
  proportionally slows the first jump and every `grr`.
- Definition positions are re-read whenever a file's mtime changes, so
  ordinary edit-and-save cycles are picked up automatically. The project
  index itself (which files and libraries exist) refreshes only on
  `:MasmRebuildIndex`, so run that after creating, deleting or moving
  `.masm` files or `miden-project.toml` manifests.
- Hover shows what the definition site says (doc comment, signature). The
  bundled instruction reference is generated from Trail of Bits'
  [masm-lsp](https://github.com/trailofbits/masm-lsp) metadata and pins that
  snapshot of the Miden docs.
- Stack analysis is a static approximation, not the assembler: absence of
  diagnostics is not a correctness proof. Procedures without a
  `#! Invocation:` doc tag (or a script attribute with a padded 16-element
  `Inputs:` contract) are skipped -- that includes most kernel-internal code
  by design. `dynexec`/`dyncall` targets and `exec` callees without parseable
  `Inputs:/Outputs:` contracts make the state unknown until the next
  handwritten `# => [...]` comment resynchronizes it (opt into seeing these
  with `bail_hints`). An `exec` whose consumption reaches the 16-element
  stack floor has an internals-dependent exact depth and is likewise
  resynchronized from the next comment. Comments in `exec`-invoked
  procedures are checked for adoption but never flagged (they legitimately
  mix declared-inputs and caller views); wrong element *order* is invisible
  whenever the widths still match. An unknown instruction skips the whole
  procedure with a stated reason rather than guessing.
- No completion or rename, and no diagnostics beyond stack analysis. For
  assembler diagnostics there is
  [miden-lsp](https://github.com/0xMiden/miden-lsp); note it derives syntax
  errors from the same stale grammar, so expect false positives on import
  headers.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Tests run with `make test` against a
self-contained fixture project; no Miden checkout is needed.

## License

[MIT](LICENSE)
