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
--    buffer-size gate here, instruction/lookup budgets in the engine, a
--    debounce so TextChanged storms collapse into one analysis, and a
--    changedtick early-out so debounced no-op triggers (InsertLeave without
--    an edit) skip the pass entirely.
--  * Only `eol` virt_text is used -- `eol_right_align` is 0.11+ and the
--    supported floor is 0.10.4.

local notation = require("masm.stacknotation")
local stack = require("masm.stack")
local util = require("masm.util")

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

-- No real .masm file approaches the hardened file-read cap. Reuse the same
-- bound for live buffers so disk and buffer analysis refuse identical input.
local MAX_BUF_BYTES = util.MAX_FILE_BYTES

-- Per-buffer state:
-- { timer, overlay (bool), notified (string), analyzed_tick (changedtick at
--   the last successful publish; the debounced path's early-out key) }.
---@class masm.StackViewState
---@field timer uv.uv_timer_t? debounce timer (nil only after detach)
---@field overlay boolean ghost-text overlay currently enabled
---@field notified string? the failure notice currently shown, if any
---@field analyzed_tick integer? changedtick at the last successful publish
---@field analyzed_cfg masm.StackViewConfig? config that produced that publish

---@type table<integer, masm.StackViewState>
local buffers = {}

---@class masm.StackViewConfig the resolved per-refresh configuration
---@field diagnostics boolean publish stack diagnostics at all
---@field overlay boolean start attached buffers with the overlay on
---@field overlay_mode '"auto"'|'"all"' ghost text only where unannotated, or everywhere
---@field check_comments boolean publish comment-stale/comment-reordered warnings
---@field bail_hints boolean publish hint-severity diagnostics too
---@field debounce_ms number edit-to-refresh debounce
local defaults = {
  diagnostics = true,
  overlay = false,
  overlay_mode = "auto", -- "auto" | "all"
  check_comments = true,
  bail_hints = false,
  debounce_ms = 300,
}

-- Per-field validity checks and the expectation named in the warning.
-- Manual checks rather than vim.validate: its table-form signature is
-- deprecated upstream and the replacement form does not exist on the
-- 0.10.4 floor, so neither spelling works everywhere we run.
local function is_bool(v)
  return type(v) == "boolean"
end
local FIELD_SPECS = {
  diagnostics = { ok = is_bool, want = "a boolean" },
  overlay = { ok = is_bool, want = "a boolean" },
  check_comments = { ok = is_bool, want = "a boolean" },
  bail_hints = { ok = is_bool, want = "a boolean" },
  overlay_mode = {
    ok = function(v)
      return v == "auto" or v == "all"
    end,
    want = '"auto" or "all"',
  },
  debounce_ms = {
    ok = function(v)
      return type(v) == "number" and v >= 0
    end,
    want = "a non-negative number",
  },
}

-- Read lazily on every refresh, like vim.g.masm_goto: no setup() call.
-- Invalid fields fall back to their defaults with a one-time actionable
-- notification: a mistyped value must degrade loudly, not quietly --
-- `overlay_mode = true` used to silently disable the "auto" gating, and
-- `debounce_ms = "300"` only worked through luv's implicit coercion.
---@return masm.StackViewConfig
local function get_config()
  local user = vim.g.masm_stack
  if user ~= nil and type(user) ~= "table" then
    vim.notify_once(
      ("masm stack: vim.g.masm_stack must be a table, got %s; using defaults"):format(type(user)),
      vim.log.levels.WARN
    )
    user = nil
  end
  user = user or {}
  local cfg = {}
  for k, v in pairs(defaults) do
    local uv = user[k]
    if uv == nil or not FIELD_SPECS[k].ok(uv) then
      if uv ~= nil then
        vim.notify_once(
          ("masm stack: vim.g.masm_stack.%s must be %s, got %s; using the default (%s)"):format(
            k,
            FIELD_SPECS[k].want,
            vim.inspect(uv),
            vim.inspect(v)
          ),
          vim.log.levels.WARN
        )
      end
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

---@param bufnr integer
---@param result masm.StackResult
---@param cfg masm.StackViewConfig
---@param drift {lnum: integer}[]? unrecognized-import lines (masm.goto)
local function publish(bufnr, result, cfg, drift)
  local items = {}
  if cfg.diagnostics then
    for _, d in ipairs(result.diagnostics) do
      local skip = (d.severity == "hint" and not cfg.bail_hints)
        or ((d.code == "comment-stale" or d.code == "comment-reordered") and not cfg.check_comments)
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
---@param line string
---@return boolean
local function has_tracker(line)
  local comment = notation.comment_part(line)
  if not comment then
    return false
  end
  return notation.tracker_kind(comment) == "tracker"
end

-- `lines` is the refresh's single buffer read, passed through.
---@param bufnr integer
---@param result masm.StackResult
---@param cfg masm.StackViewConfig
---@param lines string[]
local function render_overlay(bufnr, result, cfg, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, mark_ns, 0, -1)
  -- Lines the engine flagged as stale keep their ghost text even in "auto"
  -- mode: the corrected state IS the payload there.
  local stale = {}
  for _, d in ipairs(result.diagnostics) do
    if d.code == "comment-stale" or d.code == "comment-reordered" then
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
-- nil/0 normalize to the current buffer, exactly like attach/toggle/detach
-- (refresh(nil) used to silently no-op while the siblings accepted it).
---@param bufnr integer? nil/0 = current buffer
function M.refresh(bufnr)
  bufnr = util.norm_bufnr(bufnr)
  local state = buffers[bufnr]
  if not state then
    return
  end
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local cfg = get_config()
  -- Failure notices run from edit-driven autocmds, so each is shown once --
  -- but latched on the MESSAGE, not a boolean: a new, different failure
  -- must never be swallowed because an old one already notified, and a
  -- recovery (successful publish clears the latch below) re-arms it.
  local function notify_once(msg)
    if state.notified ~= msg then
      state.notified = msg
      vim.notify(msg, vim.log.levels.WARN)
    end
  end
  if vim.api.nvim_buf_get_offset(bufnr, vim.api.nvim_buf_line_count(bufnr)) > MAX_BUF_BYTES then
    notify_once("masm stack: buffer too large, analysis disabled")
    return
  end
  -- One buffer read serves the whole refresh: the analysis, the drift
  -- canary and the overlay's tracker checks all consume the same lines
  -- (going through stack.analyze re-read the buffer, and the canary
  -- concatenated a second copy of it).
  local path = vim.api.nvim_buf_get_name(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- Captured WITH the lines, not after publish: vim.diagnostic.set fires
  -- DiagnosticChanged synchronously, and a user autocmd there that edits the
  -- buffer would otherwise smuggle its post-edit tick into analyzed_tick --
  -- describing lines that were never analyzed, and pinning the stale publish
  -- until some unrelated edit.
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  -- Last-resort containment: this runs from TextChanged/InsertLeave
  -- autocmds, and one uncaught nil deep in the simulator would otherwise
  -- become a repeating error notification on every edit. The engine's own
  -- contract is to return reasons, so tripping this is a bug -- but a
  -- contained one.
  local an_ok, result, reason
  if path == "" then
    an_ok, result, reason = true, nil, "unnamed buffer"
  else
    an_ok, result, reason = pcall(stack.analyze_lines, lines, path)
  end
  if not an_ok then
    result, reason = nil, "internal analyzer error: " .. tostring(result)
  end
  if not result then
    -- Unnamed buffer or index failure: clear our output, say why once.
    vim.diagnostic.reset(diag_ns, bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, mark_ns, 0, -1)
    notify_once("masm stack: " .. reason)
    return
  end
  local drift = require("masm.goto").unrecognized_imports(table.concat(lines, "\n"))
  publish(bufnr, result, cfg, drift)
  if state.overlay then
    render_overlay(bufnr, result, cfg, lines)
  else
    vim.api.nvim_buf_clear_namespace(bufnr, mark_ns, 0, -1)
  end
  -- Records what was published so the debounced path can skip a no-op
  -- re-analysis (InsertLeave without an edit). Only set after a successful
  -- publish: failed attempts stay retryable. The config snapshot rides
  -- along because the skip is only sound while the config that produced the
  -- publish still holds ("read lazily on every refresh" must survive the
  -- early-out).
  state.analyzed_tick = tick
  state.analyzed_cfg = cfg
  state.notified = nil -- recovered: the next failure (even a repeat) notifies
end

-- Finds inaccurate handwritten operand-stack comments across every file in
-- the current project index. The scan is asynchronous by default and shares
-- the cooperative driver/cancellation semantics used by project references;
-- sync mode exists for tests and callers that explicitly accept blocking.
---@param opts {sync: boolean?}?
---@return {filename: string, lnum: integer, col: integer, type: string, text: string}[]? items
function M.comments(opts)
  opts = opts or {}
  local bufpath = vim.api.nvim_buf_get_name(0)
  if bufpath == "" then
    vim.notify("masm stack comments: unnamed buffer", vim.log.levels.WARN)
    return
  end

  local ok, index = pcall(require("masm.project").build_index, bufpath)
  if not ok then
    vim.notify("masm stack comments: indexing failed: " .. tostring(index), vim.log.levels.ERROR)
    return
  end

  local scanner = require("masm.scan")
  local items = {}
  local scan
  scan = {
    files = index.masm,
    sync = opts.sync,
    visit = function(path, text)
      if #text > MAX_BUF_BYTES then
        error("file exceeds analysis size limit")
      end
      local result, reason = stack.analyze_lines(vim.split(text, "\n", { plain = true }), path)
      if not result then
        error(reason or "analysis failed")
      end
      for _, diagnostic in ipairs(result.diagnostics) do
        if diagnostic.code == "comment-stale" or diagnostic.code == "comment-reordered" then
          items[#items + 1] = {
            filename = path,
            lnum = diagnostic.lnum,
            col = (diagnostic.col or 0) + 1,
            type = "W",
            text = ("[%s] %s"):format(diagnostic.code, diagnostic.message),
          }
        end
      end
    end,
    on_done = function()
      local stale, restarted = scanner.restart_stale(scan, function()
        items = {}
      end)
      if stale then
        if not restarted then
          vim.notify(
            "masm stack comments: buffers changed while scanning; rerun",
            vim.log.levels.WARN
          )
        end
        return
      end

      table.sort(items, function(a, b)
        if a.filename ~= b.filename then
          return a.filename < b.filename
        end
        if a.lnum ~= b.lnum then
          return a.lnum < b.lnum
        end
        if a.col ~= b.col then
          return a.col < b.col
        end
        return a.text < b.text
      end)
      vim.fn.setqflist({}, " ", { title = "MASM inaccurate stack comments", items = items })
      if (scan.errors or 0) > 0 then
        vim.notify(
          ("masm stack comments: failed to analyze %d file(s); results are partial"):format(
            scan.errors
          ),
          vim.log.levels.WARN
        )
      end
      if #items == 0 then
        if (scan.errors or 0) == 0 then
          vim.notify(
            "masm stack comments: all indexed stack comments are accurate",
            vim.log.levels.INFO
          )
        end
        return
      end
      vim.cmd("botright copen")
    end,
  }
  scanner.start(scan)
  if opts.sync then
    return #items > 0 and items or nil
  end
end

---@param bufnr integer
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
      -- Changedtick early-out, debounced path ONLY: InsertLeave fires on
      -- every insert-mode exit whether or not an edit happened, and a
      -- no-edit exit would otherwise re-run the full analysis for an
      -- identical publish. Direct refresh() calls (BufWritePost, toggle,
      -- tests) always run: writes change file mtimes the contract caches
      -- key on, and toggling must re-render regardless of edits.
      local st = buffers[bufnr]
      if
        st
        and st.analyzed_tick
        and vim.api.nvim_buf_is_loaded(bufnr)
        and vim.api.nvim_buf_get_changedtick(bufnr) == st.analyzed_tick
        and vim.deep_equal(get_config(), st.analyzed_cfg)
      then
        return
      end
      M.refresh(bufnr)
    end)
  )
end

-- Toggles the ghost-text overlay for the buffer (:MasmStackToggle).
---@param bufnr integer? nil/0 = current buffer
function M.toggle(bufnr)
  bufnr = util.norm_bufnr(bufnr)
  local state = buffers[bufnr]
  if not state then
    return
  end
  state.overlay = not state.overlay
  M.refresh(bufnr)
end

-- Wires the analyzer to the buffer: debounced refresh on edits, immediate
-- refresh on write, teardown on unload. Idempotent per buffer.
---@param bufnr integer? nil/0 = current buffer
function M.attach(bufnr)
  bufnr = util.norm_bufnr(bufnr)
  if buffers[bufnr] then
    return
  end
  local cfg = get_config()
  buffers[bufnr] = {
    -- util.uv, not bare vim.uv: the supported floor predates the rename
    -- being universal, and every other module already aliases it.
    timer = util.uv.new_timer(),
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
---@param bufnr integer? nil/0 = current buffer
function M.detach(bufnr)
  bufnr = util.norm_bufnr(bufnr)
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
