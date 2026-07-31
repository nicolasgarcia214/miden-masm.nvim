-- UI layer for the stack analyzer (masm.stack): publishes diagnostics and
-- renders the inferred-stack overlay.
--
-- Design constraints that shape this module:
--  * Diagnostics are PUBLISHED through vim.diagnostic in our own namespace
--    and never rendered here -- the user's diagnostic config decides
--    presentation. The overlay lives in a second, separate namespace so
--    vim.diagnostic.reset cannot clobber overlay extmarks (and vice versa).
--  * The overlay is eol virtual text, not virt_lines: Miden's own idiom puts
--    `# => [...]` at/after the instruction, and virt_lines shift every line
--    below them while typing. In "auto" mode ghost text appears only where
--    no handwritten `# =>` comment exists -- well-annotated files stay
--    visually unchanged; overlay value concentrates on unannotated code.
--  * All work is synchronous on the UI thread and therefore bounded: a
--    buffer-size gate here, instruction/lookup budgets in the engine, and a
--    debounce so TextChanged storms collapse into one analysis.
--  * Only `eol` virt_text is used -- `eol_right_align` is 0.11+ and the
--    supported floor is 0.10.4.

local M = {}

local diag_ns = vim.api.nvim_create_namespace("masm.stack.diagnostics")
local mark_ns = vim.api.nvim_create_namespace("masm.stack.overlay")

-- Ghost text must look different from real Comment-highlighted `# =>`
-- comments so users don't try to edit it; NonText is the dimmer channel.
-- `:colorscheme` clears plugin-defined groups, so re-apply on ColorScheme.
local function define_highlights()
  vim.api.nvim_set_hl(0, "MasmStackVirtualText", { link = "NonText", default = true })
  vim.api.nvim_set_hl(
    0,
    "MasmStackVirtualTextStale",
    { link = "DiagnosticVirtualTextWarn", default = true }
  )
end
define_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("masm_stack_highlights", { clear = true }),
  callback = define_highlights,
})

-- Buffers larger than this are never analyzed (same philosophy as goto's
-- MAX_FILE_BYTES: no real .masm file approaches it).
local MAX_BUF_BYTES = 2 * 1024 * 1024

-- Per-buffer state: { timer, tick, overlay (bool), notified (bool) }.
local buffers = {}

local defaults = {
  diagnostics = true,
  overlay = false,
  overlay_mode = "auto", -- "auto" | "all"
  check_comments = true,
  bail_hints = false,
  debounce_ms = 300,
}

-- Read lazily on every refresh, like vim.g.masm_goto: no setup() call.
local function get_config()
  local user = vim.g.masm_stack
  if type(user) ~= "table" then
    user = {}
  end
  local cfg = {}
  for k, v in pairs(defaults) do
    local uv = user[k]
    if uv == nil then
      cfg[k] = v
    else
      cfg[k] = uv
    end
  end
  return cfg
end

local SEVERITIES = {
  error = vim.diagnostic.severity.ERROR,
  warn = vim.diagnostic.severity.WARN,
  hint = vim.diagnostic.severity.HINT,
}

local function publish(bufnr, result, cfg, drift)
  local items = {}
  if cfg.diagnostics then
    for _, d in ipairs(result.diagnostics) do
      local skip = (d.severity == "hint" and not cfg.bail_hints)
        or (d.code == "comment-stale" and not cfg.check_comments)
      if not skip then
        items[#items + 1] = {
          lnum = d.lnum - 1,
          col = d.col or 0,
          severity = SEVERITIES[d.severity] or vim.diagnostic.severity.WARN,
          message = d.message,
          code = d.code,
          source = "masm-stack",
        }
      end
    end
    -- Dialect-drift canary (masm.goto): a `use` form the resolver does not
    -- recognize would otherwise fail silently -- imports not seen, navigation
    -- and callee contracts quietly degraded. Surfacing it here turns grammar/
    -- dialect drift into a visible signal on the offending line.
    for _, u in ipairs(drift or {}) do
      items[#items + 1] = {
        lnum = u.lnum - 1,
        col = 0,
        severity = vim.diagnostic.severity.WARN,
        message = "unrecognized use-statement form (dialect drift?): navigation will not see this import",
        code = "unrecognized-import",
        source = "masm-goto",
      }
    end
  end
  vim.diagnostic.set(diag_ns, bufnr, items)
end

-- True when the raw line already carries a handwritten operand-stack
-- tracker (`# => [...]` / `# OS => [...]`).
local function has_tracker(line)
  local notation = require("masm.stacknotation")
  local comment = notation.comment_part(line)
  if not comment then
    return false
  end
  return notation.tracker_kind(comment) == "tracker"
end

local function render_overlay(bufnr, result, cfg)
  vim.api.nvim_buf_clear_namespace(bufnr, mark_ns, 0, -1)
  local stack = require("masm.stack")
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- Lines the engine flagged as stale keep their ghost text even in "auto"
  -- mode: the corrected state IS the payload there.
  local stale = {}
  for _, d in ipairs(result.diagnostics) do
    if d.code == "comment-stale" then
      stale[d.lnum] = true
    end
  end
  for _, proc in ipairs(result.procs) do
    if proc.bailed then
      vim.api.nvim_buf_set_extmark(bufnr, mark_ns, proc.lnum - 1, 0, {
        virt_text = { { "  # => ? (" .. proc.bailed .. ")", "MasmStackVirtualText" } },
        virt_text_pos = "eol",
        hl_mode = "combine",
      })
    else
      for lnum, state in pairs(proc.states) do
        local line = lines[lnum]
        -- A tracker on the line itself, or on the next line (the dominant
        -- corpus style), already annotates this state by hand.
        local annotated = line
          and (
            has_tracker(line)
            or (lines[lnum + 1] and has_tracker(lines[lnum + 1]) and lines[lnum + 1]:match("^%s*#"))
          )
        local show = cfg.overlay_mode == "all" or stale[lnum] or (line and not annotated)
        -- Own-line trackers (comment-only lines) never get ghost text: the
        -- handwritten value is already there.
        if line and line:match("^%s*#") then
          show = stale[lnum]
        end
        if show then
          local hl = stale[lnum] and "MasmStackVirtualTextStale" or "MasmStackVirtualText"
          vim.api.nvim_buf_set_extmark(bufnr, mark_ns, lnum - 1, 0, {
            virt_text = { { "  # => " .. stack.render_cells(state), hl } },
            virt_text_pos = "eol",
            hl_mode = "combine",
          })
        end
      end
    end
  end
end

-- The synchronous pipeline; also the test hook (no timers involved).
function M.refresh(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local state = buffers[bufnr]
  if not state then
    return
  end
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local cfg = get_config()
  if vim.api.nvim_buf_get_offset(bufnr, vim.api.nvim_buf_line_count(bufnr)) > MAX_BUF_BYTES then
    if not state.notified then
      state.notified = true
      vim.notify("masm stack: buffer too large, analysis disabled", vim.log.levels.WARN)
    end
    return
  end
  local stack = require("masm.stack")
  local result, reason = stack.analyze(bufnr)
  if not result then
    -- Unnamed buffer or index failure: clear our output, say why once.
    vim.diagnostic.reset(diag_ns, bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, mark_ns, 0, -1)
    if not state.notified then
      state.notified = true
      vim.notify("masm stack: " .. reason, vim.log.levels.WARN)
    end
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local drift = require("masm.goto").unrecognized_imports(table.concat(lines, "\n"))
  publish(bufnr, result, cfg, drift)
  if state.overlay then
    render_overlay(bufnr, result, cfg)
  else
    vim.api.nvim_buf_clear_namespace(bufnr, mark_ns, 0, -1)
  end
end

local function schedule_refresh(bufnr)
  local state = buffers[bufnr]
  if not state or not state.timer then
    return
  end
  local cfg = get_config()
  state.timer:stop()
  state.timer:start(
    cfg.debounce_ms,
    0,
    vim.schedule_wrap(function()
      M.refresh(bufnr)
    end)
  )
end

function M.toggle(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local state = buffers[bufnr]
  if not state then
    return
  end
  state.overlay = not state.overlay
  M.refresh(bufnr)
end

function M.attach(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if buffers[bufnr] then
    return
  end
  local cfg = get_config()
  buffers[bufnr] = {
    timer = vim.uv.new_timer(),
    overlay = cfg.overlay and true or false,
  }
  local group = vim.api.nvim_create_augroup("masm_stack_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "InsertLeave", "TextChanged" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      schedule_refresh(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = bufnr,
    callback = function()
      -- Saves change file mtimes (contract caches key on them) and users
      -- expect fresh state on write: run now, no debounce.
      M.refresh(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    buffer = bufnr,
    callback = function()
      M.detach(bufnr)
    end,
  })
  -- Never block the file-open path: the first pass may build goto's project
  -- index (documented as first-jump cost).
  vim.schedule(function()
    M.refresh(bufnr)
  end)
end

-- Idempotent: teardown may run twice (undo_ftplugin + BufUnload).
function M.detach(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local state = buffers[bufnr]
  if not state then
    return
  end
  buffers[bufnr] = nil
  if state.timer then
    state.timer:stop()
    state.timer:close()
  end
  pcall(vim.api.nvim_del_augroup_by_name, "masm_stack_" .. bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, mark_ns, 0, -1)
    vim.diagnostic.reset(diag_ns, bufnr)
  end
end

-- Exposed for tests and health.
M._diag_ns = diag_ns
M._mark_ns = mark_ns

return M
