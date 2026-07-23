-- Tests after/ftplugin/masm.lua setup AND teardown. The teardown chain is
-- easy to break silently (a bar-swallowing command aborts the rest under
-- `silent!`), so this asserts the state after `:setf masm` and again after
-- switching filetype away.
-- Run with: nvim --headless -u NONE -l tests/ftplugin_test.lua (or make test)

local script = debug.getinfo(1, "S").source:sub(2)
local here = vim.fs.dirname(vim.fn.fnamemodify(script, ":p"))
local plugin_root = vim.fs.dirname(here)
vim.opt.rtp:prepend(plugin_root)
vim.opt.rtp:append(plugin_root .. "/after")

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
check("shiftwidth 4", vim.bo.shiftwidth == 4)
check("gd mapped", buf_mapped("gd"))
check("grr mapped", buf_mapped("grr"))
check("gO mapped", buf_mapped("gO"))
check("command exists", vim.fn.exists(":MasmRebuildIndex") == 2)

-- Teardown: switching filetype must undo EVERYTHING; in particular the tail
-- of the undo chain (mappings, command) must run, proving no command in the
-- chain swallowed the following bar.
vim.bo.filetype = "text"
check("teardown: tagfunc cleared", vim.bo.tagfunc == "", vim.bo.tagfunc)
check("teardown: gd unmapped", not buf_mapped("gd"))
check("teardown: grr unmapped", not buf_mapped("grr"))
check("teardown: gO unmapped", not buf_mapped("gO"))
check("teardown: command removed", vim.fn.exists(":MasmRebuildIndex") == 0)
check("teardown: match_words cleared", vim.b.match_words == nil)

-- Opt-out flag: reload as masm with mappings disabled.
vim.g.masm_no_default_mappings = true
vim.bo.filetype = "masm"
check("opt-out: no gd mapping", not buf_mapped("gd"))
check("opt-out: tagfunc still set", vim.bo.tagfunc:find("masm.goto", 1, true) ~= nil)
vim.g.masm_no_default_mappings = nil

print(failed == 0 and "ALL PASS" or (failed .. " FAILURES"))
if failed > 0 then
  os.exit(1)
end
