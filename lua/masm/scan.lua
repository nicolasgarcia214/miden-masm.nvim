-- Cooperative project-file scanning shared by quickfix producers. The
-- project index decides WHICH files belong to a scan; this module only reads
-- them with live-buffer-wins semantics, visits them in bounded time slices,
-- and prevents an older scan from landing after a newer one.

local util = require("masm.util")

local M = {}

local uv = util.uv
local active_scan
local SCAN_SLICE_MS = 10
local MAX_SCAN_RESTARTS = 3

-- Test hook: real fixture projects finish inside one slice, so hardening
-- tests lower this to make cancellation and stale-restart paths observable.
M._slice_ms = nil

-- Text for one indexed file. Any loaded buffer wins over disk, including a
-- clean one: its visible line numbers are what a quickfix jump must describe.
-- Disk reads retain util.read_file's regular-file and size bounds.
---@param path string
---@param ticks table<integer, integer>? changedticks observed during an async scan
---@return string? text
function M.file_text(path, ticks)
  local bufnr = util.loaded_bufnr(path)
  if bufnr then
    if ticks then
      ticks[bufnr] = vim.api.nvim_buf_get_changedtick(bufnr)
    end
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  end
  return util.read_file(path)
end

---@class masm.ProjectScan
---@field files string[] indexed files to visit
---@field sync boolean? run without yielding (tests and atomic callers only)
---@field visit fun(path: string, text: string)
---@field on_done fun()
---@field i integer? next file index
---@field errors integer? unreadable/failed visitor count
---@field ticks table<integer, integer>? changedticks captured while reading
---@field cancelled boolean? superseded by a newer scan
---@field restarts integer? stale-result restart count

---@param scan masm.ProjectScan
local function run(scan)
  local deadline = scan.sync and math.huge
    or (uv.hrtime() + (M._slice_ms or SCAN_SLICE_MS) * 1e6)
  while true do
    local i = assert(scan.i)
    if i > #scan.files then
      break
    end
    if uv.hrtime() > deadline then
      vim.schedule(function()
        if not scan.cancelled then
          run(scan)
        end
      end)
      return
    end
    local path = scan.files[i]
    scan.i = i + 1
    local text = M.file_text(path, scan.ticks)
    if text then
      -- One unreadable or pathological file must not kill the whole scan.
      if not pcall(scan.visit, path, text) then
        scan.errors = (scan.errors or 0) + 1
      end
    else
      scan.errors = (scan.errors or 0) + 1
    end
  end
  if scan == active_scan then
    active_scan = nil
  end
  scan.on_done()
end

-- Starts (or restarts) a scan. Quickfix scans intentionally share one active
-- slot: the newest user request owns the eventual quickfix result.
---@param scan masm.ProjectScan
function M.start(scan)
  if active_scan then
    active_scan.cancelled = true
    active_scan = nil
  end
  scan.cancelled = false
  if not scan.sync then
    active_scan = scan
  end
  scan.i = 1
  scan.errors = 0
  scan.ticks = {}
  run(scan)
end

-- True when a loaded buffer read by an async scan changed before completion.
-- Publishing those collected line numbers would make quickfix stale.
---@param scan masm.ProjectScan
---@return boolean
function M.stale(scan)
  for bufnr, tick in pairs(scan.ticks or {}) do
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_buf_get_changedtick(bufnr) ~= tick then
      return true
    end
  end
  return false
end

-- Applies the one shared stale-result policy. `reset` clears caller-owned
-- collected data; `current`, when supplied, confirms the scan target itself
-- still exists before retrying (references need this, comment scans do not).
---@param scan masm.ProjectScan
---@param reset fun()
---@param current (fun(): boolean)?
---@return boolean stale
---@return boolean restarted
function M.restart_stale(scan, reset, current)
  if scan.sync or not M.stale(scan) then
    return false, false
  end
  scan.restarts = (scan.restarts or 0) + 1
  if scan.restarts <= MAX_SCAN_RESTARTS and (not current or current()) then
    reset()
    M.start(scan)
    return true, true
  end
  return true, false
end

return M
