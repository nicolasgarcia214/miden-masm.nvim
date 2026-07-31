-- Tests after/ftplugin/masm.lua setup AND teardown. The teardown chain is
-- easy to break silently (a bar-swallowing command aborts the rest under
-- `silent!`), so this asserts the state after `:setf masm` and again after
-- switching filetype away.
-- Run with: nvim --headless --clean -l tests/ftplugin_test.lua (or make test)

local script = debug.getinfo(1, "S").source:sub(2)
local here = vim.fs.dirname(vim.fn.fnamemodify(script, ":p"))
local plugin_root = vim.fs.dirname(here)
vim.opt.rtp:prepend(plugin_root)
vim.opt.rtp:append(plugin_root .. "/after")
-- The rtp edit above happens after startup, so plugin/ was not sourced the
-- way a plugin manager would; source it explicitly. This is also what puts
-- the plugin's own `*.masm` filetype registration under test -- Neovim 0.10
-- has no built-in mapping and would otherwise detect `conf`.
vim.cmd("runtime! plugin/miden-masm.lua")

local failed = 0
-- Neovim 0.11+ ships GLOBAL default grr/gO (LSP) mappings, so presence must
-- be asserted on the buffer-local mapping specifically.
local function buf_mapped(lhs)
  local m = vim.fn.maparg(lhs, "n", false, true)
  return m.buffer == 1
end

local function check(desc, ok, detail)
  if ok then
    print("PASS: " .. desc)
  else
    print("FAIL: " .. desc .. (detail and (" -- " .. detail) or ""))
    failed = failed + 1
  end
end

vim.cmd("filetype plugin on")
vim.cmd("edit! " .. here .. "/fixtures/core_lib/math.masm")

check("filetype detected", vim.bo.filetype == "masm", vim.bo.filetype)
check("commentstring corrected", vim.bo.commentstring == "# %s", vim.bo.commentstring)
check("tagfunc set", vim.bo.tagfunc:find("masm.goto", 1, true) ~= nil, vim.bo.tagfunc)
check("omnifunc set", vim.bo.omnifunc:find("masm.complete", 1, true) ~= nil, vim.bo.omnifunc)
check("shiftwidth 4", vim.bo.shiftwidth == 4)
check("gd mapped", buf_mapped("gd"))
check("grr mapped", buf_mapped("grr"))
check("grn mapped", buf_mapped("grn"))
check("gO mapped", buf_mapped("gO"))
check("K mapped", buf_mapped("K"))
check("command exists", vim.fn.exists(":MasmRebuildIndex") == 2)
check("rename command exists", vim.fn.exists(":MasmRename") == 2)
check("stack command exists", vim.fn.exists(":MasmStackToggle") == 2)
local stack_autocmds = vim.api.nvim_get_autocmds({
  group = "masm_stack_" .. vim.api.nvim_get_current_buf(),
  buffer = vim.api.nvim_get_current_buf(),
})
check("stack autocmds attached", #stack_autocmds > 0)

-- Teardown: switching filetype must undo EVERYTHING; in particular the tail
-- of the undo chain (mappings, command) must run, proving no command in the
-- chain swallowed the following bar.
vim.bo.filetype = "text"
check("teardown: tagfunc cleared", vim.bo.tagfunc == "", vim.bo.tagfunc)
check("teardown: omnifunc cleared", vim.bo.omnifunc == "", vim.bo.omnifunc)
check("teardown: gd unmapped", not buf_mapped("gd"))
check("teardown: grr unmapped", not buf_mapped("grr"))
check("teardown: grn unmapped", not buf_mapped("grn"))
check("teardown: gO unmapped", not buf_mapped("gO"))
check("teardown: K unmapped", not buf_mapped("K"))
check("teardown: command removed", vim.fn.exists(":MasmRebuildIndex") == 0)
check("teardown: rename command removed", vim.fn.exists(":MasmRename") == 0)
check("teardown: stack command removed", vim.fn.exists(":MasmStackToggle") == 0)
local stackview = require("masm.stackview")
local buf = vim.api.nvim_get_current_buf()
check(
  "teardown: stack diagnostics reset",
  #vim.diagnostic.get(buf, { namespace = stackview._diag_ns }) == 0
)
check(
  "teardown: stack overlay cleared",
  #vim.api.nvim_buf_get_extmarks(buf, stackview._mark_ns, 0, -1, {}) == 0
)
local ok_autocmds = pcall(vim.api.nvim_get_autocmds, { group = "masm_stack_" .. buf })
check("teardown: stack augroup deleted", not ok_autocmds)
check("teardown: match_words cleared", vim.b.match_words == nil)

-- Opt-out flags: reload as masm with mappings and stack analysis disabled.
vim.g.masm_no_default_mappings = true
vim.g.masm_no_stack = true
vim.bo.filetype = "masm"
check("opt-out: no gd mapping", not buf_mapped("gd"))
check("opt-out: no K mapping", not buf_mapped("K"))
check("opt-out: tagfunc still set", vim.bo.tagfunc:find("masm.goto", 1, true) ~= nil)
check("opt-out: no stack command", vim.fn.exists(":MasmStackToggle") == 0)
local no_stack_autocmds =
  pcall(vim.api.nvim_get_autocmds, { group = "masm_stack_" .. vim.api.nvim_get_current_buf() })
check("opt-out: no stack autocmds", not no_stack_autocmds)
vim.g.masm_no_default_mappings = nil
vim.g.masm_no_stack = nil

print(failed == 0 and "ALL PASS" or (failed .. " FAILURES"))
if failed > 0 then
  os.exit(1)
end
