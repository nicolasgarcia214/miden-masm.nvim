local M = {}

-- `:checkhealth masm`
function M.check()
  local health = vim.health
  health.start("miden-masm.nvim")

  -- Navigation (tagfunc / references / symbols) is text-based and needs no
  -- parser, so report it first and unconditionally.
  local ok_goto = pcall(require, "masm.goto")
  if ok_goto then
    health.ok("navigation module loads (gd / <C-]> / grr / gO)")
  else
    health.error("require('masm.goto') failed -- is the plugin on 'runtimepath'?")
  end

  local ok_data, data = pcall(require, "masm.instructions")
  if pcall(require, "masm.hover") and ok_data and type(data) == "table" and #data > 0 then
    health.ok("hover module and instruction reference load (K, " .. #data .. " instructions)")
  else
    health.error("hover module or instruction reference failed to load")
  end

  local stack_ok = pcall(require, "masm.stack")
    and pcall(require, "masm.stackview")
    and pcall(require, "masm.stacknotation")
    and pcall(require, "masm.arity")
  if stack_ok then
    if vim.g.masm_no_stack then
      health.info("stack analyzer disabled (vim.g.masm_no_stack is set)")
    else
      health.ok("stack analyzer loads (diagnostics + :MasmStackToggle overlay)")
    end
  else
    health.error("stack analyzer failed to load")
  end

  if pcall(require, "masm.complete") then
    health.ok("completion module loads (<C-x><C-o> via 'omnifunc')")
  else
    health.error("require('masm.complete') failed")
  end

  -- Debugger integration is optional at every level: the module must load,
  -- but missing nvim-dap or backends only mean the feature stays off.
  -- Inspection only -- a health CHECK must not register the adapter or
  -- create commands as a side effect; registration belongs to the ftplugin.
  local dap_ok = pcall(require, "masm.dap")
  if not dap_ok then
    health.error("require('masm.dap') failed")
  elseif vim.g.masm_no_dap then
    health.info("debugger integration disabled (vim.g.masm_no_dap is set)")
  else
    local has_dap, nvim_dap = pcall(require, "dap")
    if not has_dap then
      health.info("debugger integration off: nvim-dap is not installed")
    elseif type(nvim_dap.adapters) == "table" and nvim_dap.adapters.miden then
      health.ok("miden debug adapter registered with nvim-dap (:DapNew, :MasmDapState)")
    else
      health.info("miden adapter not registered yet (happens with the first .masm buffer)")
    end
    for _, bin in ipairs({ "miden-debug", "miden-client" }) do
      if vim.fn.executable(bin) == 1 then
        health.ok(bin .. " found on PATH")
      else
        health.info(bin .. " not on PATH (needed only to launch that debug backend)")
      end
    end
  end

  if pcall(require, "nvim-treesitter") then
    health.ok("nvim-treesitter is installed")
  else
    health.warn("nvim-treesitter not found", {
      "Highlighting, indentation and folds need it; navigation works without it.",
      "https://github.com/nvim-treesitter/nvim-treesitter (main branch)",
    })
  end

  -- Probe for the parser binary on the runtimepath rather than through
  -- vim.treesitter.language.add: on Neovim 0.11+ `add` returns nil,err
  -- instead of raising, so a bare pcall(add) is always truthy and would
  -- report a missing parser as installed.
  local parser_files = vim.api.nvim_get_runtime_file("parser/masm.*", true)
  if #parser_files == 0 then
    health.warn("masm tree-sitter parser not installed", {
      "Run :TSInstall masm (requires nvim-treesitter and a C compiler).",
    })
    return
  end
  health.ok("masm tree-sitter parser found: " .. parser_files[1])

  -- Verify it actually loads (catches ABI mismatches). `add` raises on
  -- failure on 0.10 and returns nil,err on 0.11+.
  local ok, res = pcall(vim.treesitter.language.add, "masm")
  local loaded
  if vim.fn.has("nvim-0.11") == 1 then
    loaded = ok and res ~= nil and res ~= false
  else
    loaded = ok
  end
  if not loaded then
    health.error("masm parser is present but failed to load", { tostring(res) })
    return
  end
  health.ok("masm parser loads")

  for _, q in ipairs({ "highlights", "indents", "folds", "locals", "textobjects" }) do
    local qok, query = pcall(vim.treesitter.query.get, "masm", q)
    if qok and query then
      health.ok("query parses: " .. q)
    else
      health.error("query missing or invalid: " .. q)
    end
  end
end

return M
