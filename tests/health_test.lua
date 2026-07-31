-- Tests for :checkhealth masm (masm.health). The vim.health reporters are
-- stubbed to collect reports, so assertions run headlessly on any Neovim.
-- Run with: nvim --headless --clean -l tests/health_test.lua (or make test)

local helpers = dofile(
  vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")) .. "/helpers.lua"
)
local check = helpers.check

local function run_check()
  local reports = { ok = {}, error = {}, warn = {}, info = {}, start = {} }
  local real_health = vim.health
  vim.health = {}
  for level in pairs(reports) do
    vim.health[level] = function(msg)
      table.insert(reports[level], tostring(msg))
    end
  end
  local call_ok, err = pcall(require("masm.health").check)
  vim.health = real_health
  return call_ok, reports, err
end

local function any(list, frag)
  for _, m in ipairs(list) do
    if m:find(frag, 1, true) then
      return true
    end
  end
  return false
end

-- A clean environment (no nvim-treesitter, no parser, no nvim-dap): every
-- bundled module reports ok, missing optional deps are warn/info -- and
-- crucially, zero errors.
local call_ok, reports, err = run_check()
check("health: check() runs", call_ok, tostring(err))
check("health: navigation ok", any(reports.ok, "navigation module loads"))
check("health: hover + reference ok", any(reports.ok, "instruction reference load"))
check("health: stack analyzer ok", any(reports.ok, "stack analyzer loads"))
check("health: completion ok", any(reports.ok, "completion module loads"))
check("health: no errors in a clean env", #reports.error == 0, vim.inspect(reports.error))
check("health: missing treesitter is a warn", any(reports.warn, "nvim-treesitter not found"))
check("health: missing parser is a warn", any(reports.warn, "parser not installed"))
check("health: missing nvim-dap is an info", any(reports.info, "nvim-dap is not installed"))

-- The health check is an INSPECTION: it must not register the DAP adapter,
-- create :MasmDapState, or mutate any other global state as a side effect.
check("health: no :MasmDapState side effect", vim.fn.exists(":MasmDapState") == 0)

-- With nvim-dap present but the adapter not yet registered (no .masm buffer
-- opened), the check reports that fact -- still without registering.
local stub = { adapters = {}, configurations = {}, listeners = { after = {} } }
-- Redefining a loader another suite also stubs is the point of a stub.
---@diagnostic disable-next-line: duplicate-set-field
package.preload["dap"] = function()
  return stub
end
reports = select(2, run_check())
check("health: unregistered adapter is an info", any(reports.info, "not registered yet"))
check("health: adapter NOT registered by the check", stub.adapters.miden == nil)

-- Once the ftplugin has registered (simulated), the check reports ok.
stub.adapters.miden = function() end
reports = select(2, run_check())
check("health: registered adapter is an ok", any(reports.ok, "adapter registered"))

-- Opt-out flags surface as info, not errors.
vim.g.masm_no_stack = true
vim.g.masm_no_dap = true
reports = select(2, run_check())
check("health: masm_no_stack is an info", any(reports.info, "stack analyzer disabled"))
check("health: masm_no_dap is an info", any(reports.info, "debugger integration disabled"))
check("health: opt-outs produce no errors", #reports.error == 0)
vim.g.masm_no_stack = nil
vim.g.masm_no_dap = nil

helpers.finish()
