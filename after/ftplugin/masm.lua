-- Neovim's built-in `ftplugin/masm.vim` targets Microsoft Macro Assembler,
-- which comments with `;`. Miden Assembly uses `#` for line comments and `#!`
-- for doc comments, so `gcc`/`gc` would otherwise insert the wrong prefix.
vim.bo.commentstring = "# %s"
vim.bo.comments = ":#!,:#"

-- Miden MASM is written with 4-space indents (the ecosystem convention;
-- projects carry no .editorconfig to say so). Without this, the treesitter
-- indent expression set below would re-indent bodies to whatever 'shiftwidth'
-- the user's config defaults to on `=`, `o` or auto-indent. Neovim's built-in
-- editorconfig support applies after ftplugins, so a project .editorconfig
-- still wins.
vim.bo.expandtab = true
vim.bo.shiftwidth = 4
vim.bo.tabstop = 4
vim.bo.softtabstop = 4

-- Turn the tree-sitter features on when the parser is installed. This must
-- happen here: nvim-treesitter (main branch) deliberately enables nothing by
-- itself, so without these calls a plain (non-LazyVim/kickstart) setup gets
-- no highlighting, indentation or folds despite a working parser.
-- Opt out with `vim.g.masm_no_treesitter = true`.
if not vim.g.masm_no_treesitter and #vim.api.nvim_get_runtime_file("parser/masm.*", false) > 0 then
  pcall(vim.treesitter.start)
  if pcall(require, "nvim-treesitter") then
    vim.bo.indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
  end
  -- Buffer-scoped window options: they follow the buffer, not the window.
  vim.wo[0][0].foldmethod = "expr"
  vim.wo[0][0].foldexpr = "v:lua.vim.treesitter.foldexpr()"
  vim.wo[0][0].foldlevel = 99 -- folds available but open, not slammed shut
end

-- The built-in ftplugin adds `$ < > ? @` to 'iskeyword' for MASM's sigils.
-- Miden identifiers are `[A-Za-z0-9_]` plus `.` and `::` for paths; `$` is used
-- by the `$exec` / `$kernel` markers. Keep `$`, drop the rest so that `w`, `*`
-- and `<C-]>` treat `<`, `>` and `?` as punctuation again.
vim.bo.iskeyword = "@,48-57,_,36"

-- The built-in ftplugin's matchit words are `.IF`/`.ENDIF` etc. from MSVC MASM
-- and never match Miden source. Replace them with Miden's block keywords so
-- `%` jumps between them.
vim.b.match_ignorecase = false
vim.b.match_words = table.concat({
  "\\<if\\.true\\>:\\<else\\>:\\<end\\>",
  "\\<while\\.true\\>:\\<end\\>",
  "\\<repeat\\>:\\<end\\>",
  "\\<begin\\>:\\<end\\>",
  "\\<proc\\>:\\<end\\>",
}, ",")

-- Go-to-definition (lua/masm/goto.lua) via 'tagfunc', so `<C-]>`, `:tag` and
-- the tag stack all resolve Miden procs/consts/modules; `<C-t>` jumps back.
vim.bo.tagfunc = "v:lua.require'masm.goto'.tagfunc"

-- Completion (lua/masm/complete.lua) via 'omnifunc' (<C-x><C-o>): invocation
-- targets, constants and opcodes from the same index navigation uses.
vim.bo.omnifunc = "v:lua.require'masm.complete'.omnifunc"

-- Default mappings, on the same keys Neovim's built-in LSP mappings use
-- (`grr` / `gO`), which would otherwise fail here with "no LSP client".
-- References resolve through renamed re-exports, so e.g.
-- `tx::get_block_number` and `memory::get_blk_num` count as the same proc.
-- Users who prefer their own mappings (or another tool's) can set
-- `vim.g.masm_no_default_mappings = true` and call the `masm.goto` functions
-- directly; 'tagfunc' stays either way, since it only takes effect through
-- commands the user invokes.
if not vim.g.masm_no_default_mappings then
  vim.keymap.set("n", "gd", "<C-]>", { buffer = true, desc = "Goto MASM definition" })
  vim.keymap.set("n", "grr", function()
    require("masm.goto").references()
  end, { buffer = true, desc = "MASM references" })
  vim.keymap.set("n", "grn", function()
    require("masm.goto").rename()
  end, { buffer = true, desc = "MASM rename" })
  vim.keymap.set("n", "gO", function()
    require("masm.goto").document_symbols()
  end, { buffer = true, desc = "MASM document symbols" })
  -- K would otherwise run 'keywordprg' (:Man), which knows no MASM name.
  vim.keymap.set("n", "K", function()
    require("masm.hover").hover()
  end, { buffer = true, desc = "MASM hover" })
end
vim.api.nvim_buf_create_user_command(0, "MasmRename", function(cmd)
  require("masm.goto").rename(cmd.args ~= "" and cmd.args or nil)
end, { nargs = "?", desc = "Rename the MASM symbol under the cursor project-wide" })
vim.api.nvim_buf_create_user_command(0, "MasmRebuildIndex", function()
  require("masm.goto").clear_cache()
  require("masm.stack").clear_cache()
  vim.notify("masm goto: index cleared; it rebuilds on the next jump")
end, { desc = "Rebuild the MASM go-to-definition project index" })

-- Stack analysis (lua/masm/stack.lua + stackview.lua): publishes depth/ABI
-- diagnostics and offers an inferred-stack eol overlay via :MasmStackToggle.
-- `vim.g.masm_no_stack = true` wires nothing at all -- the zero-cost opt-out,
-- matching masm_no_treesitter / masm_no_default_mappings.
if not vim.g.masm_no_stack then
  require("masm.stackview").attach(0)
  vim.api.nvim_buf_create_user_command(0, "MasmStackToggle", function()
    require("masm.stackview").toggle(0)
  end, { desc = "Toggle the inferred-stack ghost-text overlay" })
end

-- Let `:setfiletype` teardown undo everything we set above. `silent!`
-- everywhere: if another plugin already removed a mapping, teardown must
-- still run to completion. The separator is prepended conditionally: with an
-- empty base, a leading `|` would itself be an error and abort the chain.
-- Two traps in this chain (both found the hard way):
--   * `:lua` would swallow everything after a `|` as Lua source (:h :bar)
--     and silently abort the rest; `:call v:lua...` respects the bar.
--   * a bare `nunmap <buffer> gd | ...` leaves a trailing space on the lhs
--     (:h map-trailing-white), unmapping nothing under `silent!`; wrapping
--     each unmap in :exe with a quoted string keeps the lhs exact.
local undo = "setl commentstring< comments< iskeyword< tagfunc< omnifunc<"
  .. " | setl expandtab< shiftwidth< tabstop< softtabstop<"
  .. " | setl indentexpr< foldmethod< foldexpr< foldlevel<"
  .. " | silent! call v:lua.vim.treesitter.stop()"
  .. " | unlet! b:match_words b:match_ignorecase"
  .. " | exe 'silent! nunmap <buffer> gd'"
  .. " | exe 'silent! nunmap <buffer> grr'"
  .. " | exe 'silent! nunmap <buffer> grn'"
  .. " | exe 'silent! nunmap <buffer> gO'"
  .. " | exe 'silent! nunmap <buffer> K'"
  .. " | silent! delcommand -buffer MasmRename"
  .. " | silent! delcommand -buffer MasmRebuildIndex"
  .. " | silent! call v:lua.require'masm.stackview'.detach()"
  .. " | silent! delcommand -buffer MasmStackToggle"
local base = vim.b.undo_ftplugin
vim.b.undo_ftplugin = (base and base ~= "" and base .. " | " or "") .. undo
