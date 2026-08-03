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
  correctly. The scan runs time-sliced on the event loop -- the deadline is
  checked between files, so even a huge `extra_roots` keeps the UI
  responsive (a single enormous file is still scanned in one uninterrupted
  slice).
- Project-wide rename (`grn` / `:MasmRename`): renames the definition, every
  reference that spells the definition-site name, and the original side of
  `use { orig as alias }` items -- alias spellings correctly survive. Edits
  land in buffers, unsaved, for review.
- Completion (`<C-x><C-o>`): after `exec.`/`call.`/`syscall.`/`procref.`
  the resolvable targets (with each proc's `[inputs] -> [outputs]` contract
  in the menu), after `push.` the visible constants, and at instruction
  position every opcode with its stack effect from the instruction
  reference.
- Document symbols (`gO`) into the location list.
- Debugging via [nvim-dap](https://github.com/mfussenegger/nvim-dap) (optional):
  the plugin registers a `miden` adapter that attaches to a running Miden
  DAP server or launches `miden-debug` / `miden-client exec` with
  `--start-debug-adapter`, waiting for the server's readiness handshake.
  `:MasmDapState` shows the VM cycle, operand stack and call stack the
  adapter pushes before each stop.
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
  annotation. Comments that list the right elements in the wrong order --
  the swapped-operands documentation bug width checking cannot see -- are
  flagged whenever both sides are fully named.
- A dialect-drift canary: resolution is text-based against the current
  dialect's import forms, and a future form the resolver does not recognize
  would otherwise fail silently. Any such `use` statement is published as an
  `unrecognized-import` diagnostic instead.
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
- [nvim-dap](https://github.com/mfussenegger/nvim-dap), plus `miden-debug`
  and/or `miden-client` builds supporting `--start-debug-adapter`, for the
  optional debugger

Supported platforms: Linux and macOS, both covered by CI. Windows is
untested and unsupported -- path handling throughout the plugin is POSIX
(`/` separators, no drive letters), so expect navigation and indexing to
break there rather than degrade gracefully.

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
  `use` statement importing that module. The scan runs in the background;
  the quickfix list opens when it completes.
- `grn` or `:MasmRename [name]` - rename the symbol under the cursor
  project-wide. Edits are applied to buffers and left unsaved for review
  (`:wa` writes them, or undo per buffer). Sites importing the symbol under
  an `as` alias keep their alias -- it still resolves. Renaming onto a name
  already defined in the same file is refused (it would silently merge the
  two symbols), and procs named after opcodes never drag bare instruction
  tokens into the edit.
- `<C-x><C-o>` (insert mode) - complete invocation targets, constants and
  opcodes from the same index navigation uses; proc candidates show their
  `[inputs] -> [outputs]` contract, opcodes their stack effect.
- `gO` - list the buffer's definitions (procs, consts, types, submodules,
  entrypoint) in the location list.
- `:MasmRebuildIndex` - drop the cached project index (see below).
- `:MasmStackToggle` - toggle the inferred-stack ghost-text overlay for this
  buffer. Stack diagnostics are on by default and refresh on `InsertLeave`,
  normal-mode edits (debounced) and every write; they render through your
  normal `vim.diagnostic` configuration under the source name `masm-stack`
  (`masm-goto` for the import-form canary).

## Debugging

With [nvim-dap](https://github.com/mfussenegger/nvim-dap) installed the
plugin registers a `miden` adapter and three default configurations (your
own `dap.configurations.masm` wins if you define one): debug the current
file with `miden-debug`, debug a transaction script with
`miden-client exec`, or attach to a DAP server on `127.0.0.1:4711`. Launch
configs accept the same keys as the Miden VS Code extension: `program`,
`midenDebugPath`, `inputs`, `entrypoint`, `sysroot`, `searchPath`,
`linkLibraries`, `sourcePathPrefixes`, `programArgs` (miden-debug);
`scriptPath`, `midenClientPath`, `accountId` (miden-client); `runtime`
(`"debugger"`/`"client"`, inferred from `program`/`scriptPath` when
omitted); `host`, `port`, `cwd` (both) -- with
`${file}`/`${workspaceFolder}` substitution. The `miden*Path` keys override
which executable is spawned. The
adapter waits for the backend's readiness line instead of probing the port
-- the server accepts a single DAP connection and a probe would consume it.
`:MasmDapState` shows the VM cycle, operand stack and call stack pushed via
the `miden/uiState` event before each stop. See `:h miden-masm-dap`.

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

On a large real-world project (the Miden protocol monorepo, ~165 indexed
files, ~33k lines) a cold references scan -- index build included -- takes
~260 ms and a warm one ~200 ms; go-to-definition resolution is ~0.3 ms once
the index is built, and stack analysis of the largest file (~2k lines) is
~8 ms cold, ~2 ms warm. Measured with the bundled benchmark, which you can
run against your own project:
`nvim --headless --clean -l scripts/bench.lua <project-root>`.

## Configuration

Optional, via `vim.g.masm_goto` (set it before the first `.masm` buffer is
opened, or run `:MasmRebuildIndex` after changing it):

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

-- Set this to define your own keymaps instead of the default gd/grr/grn/gO/K
-- (call require("masm.goto").references() / .rename() / .document_symbols()
-- and require("masm.hover").hover() directly -- see :h miden-masm-api;
-- 'tagfunc' and 'omnifunc' stay active either way, so <C-]>, :tag and
-- <C-x><C-o> keep working).
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

-- Set this to keep the plugin away from nvim-dap entirely.
vim.g.masm_no_dap = true
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
  grammar cannot. The pin is upstream HEAD -- there is no newer revision to
  take; if the dialect grows an import form the resolver does not know
  either, the `unrecognized-import` canary reports it instead of silently
  missing it.
- Navigation is resolution by convention, not by executing the assembler:
  it does not model conditional compilation, shadowing, or dialect corners
  the regexes do not cover. Unresolvable names report a reason (e.g. which
  module was not found) rather than guessing.
- `std::` / `miden::core::` targets need `extra_roots` (see above), since
  those sources ship with miden-vm, not with user projects.
- Re-export chains are followed up to 5 hops; deeper chains report "not
  found". Cyclic chains are detected and fail cleanly. Resolution results
  are freshness-keyed on every file the lookup consulted, so editing any
  hop of a chain (including the middle) re-resolves on the next jump. A
  multi-line `use { .. } from` block longer than 40 lines is not recognized
  from inside its braces.
- The project index is one bounded directory walk. It is built by the first
  stack-analysis pass, scheduled a moment after the first `.masm` buffer
  opens (stack analysis is on by default); with `vim.g.masm_no_stack` set,
  it is built synchronously by whichever feature needs it first — a jump,
  or the first `<C-x><C-o>` completion, which then pays the walk while you
  are typing. References and
  rename scans read every loaded buffer's
  live text (falling back to disk); references run time-sliced in the
  background, while rename deliberately scans synchronously so its
  positions cannot race your edits.
- Rename rewrites the definition-site spelling wherever it appears; alias
  spellings (`use { x as y }`) keep their alias, and generated code or
  docs outside `.masm` files are not touched.
- Definition positions are re-read whenever a file's mtime changes, so
  ordinary edit-and-save cycles are picked up automatically, and saving a
  new `.masm` file or a `miden-project.toml` from Neovim refreshes the
  project index itself. Deleting or moving files, and changes made outside
  Neovim (`git pull`), still need `:MasmRebuildIndex`.
- Hover shows what the definition site says (doc comment, signature). The
  bundled instruction reference is generated from Trail of Bits'
  [masm-lsp](https://github.com/trailofbits/masm-lsp) metadata and pins that
  snapshot of the Miden docs, plus hand-maintained entries for mnemonics the
  snapshot lacks -- a consistency test keeps every instruction the stack
  analyzer simulates documented in hover/completion too.
- Stack analysis is a static approximation, not the assembler: absence of
  diagnostics is not a correctness proof. Procedures without a
  `#! Invocation:` doc tag (or a script attribute with a padded 16-element
  `Inputs:` contract) are skipped -- that includes most kernel-internal code
  by design. `begin` entrypoint blocks are always analyzed (they run on the
  16-element physical stack; ending deeper than 16 is an error, since the
  VM caps program stack outputs at 16). `dynexec`/`dyncall` targets and `exec` callees without parseable
  `Inputs:/Outputs:` contracts make the state unknown until the next
  handwritten `# => [...]` comment resynchronizes it (opt into seeing these
  with `bail_hints`). An `exec` whose consumption reaches the 16-element
  stack floor has an internals-dependent exact depth and is likewise
  resynchronized from the next comment. That never-warn-on-unknowable rule
  trades away one real warning: elements genuinely consumed from the
  caller *before* a later instruction poisons the state go unreported as
  caller-underflow unless a `# => [...]` resync clears the unknown state
  before the procedure ends. Comments in `exec`-invoked
  procedures are checked for adoption but never flagged (they legitimately
  mix declared-inputs and caller views); wrong element *order* is caught
  only when both the comment and the simulation are fully named with
  matching name multisets -- renamed elements in the wrong order remain
  invisible. An unknown instruction skips the whole procedure with a stated
  reason rather than guessing -- as do a positional index the assembler
  rejects (`movup.99`) and body tokens sharing the `proc` declaration line.
- Debugging requires nvim-dap and miden-debug / miden-client builds that
  support `--start-debug-adapter`.
- No assembler diagnostics beyond stack analysis and the import canary. For
  those there is [miden-lsp](https://github.com/0xMiden/miden-lsp) (usable
  alongside this plugin via `vim.lsp.start`); note it derives syntax errors
  from the same stale grammar, so expect false positives on import headers.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Tests run with `make test` against a
self-contained fixture project; no Miden checkout is needed.

## License

[MIT](LICENSE)
