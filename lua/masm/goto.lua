-- Go-to-definition for Miden Assembly (.masm) -- the public facade over the
-- project index (masm.project) and the resolution engine (masm.resolve).
--
-- Wired up as a buffer-local 'tagfunc' from `after/ftplugin/masm.lua`, so
-- `<C-]>`, `gd`, `:tag` and the tag stack (`<C-t>`) all work in .masm buffers.
-- This module keeps the cursor context, references, rename, document symbols
-- and every documented entry point; the index walk and manifest parsing live
-- in masm.project, use-statement parsing and symbol resolution in
-- masm.resolve.
--
-- Configuration (optional):
--   vim.g.masm_goto = {
--     -- Extra directories to scan for miden-project.toml libraries, e.g. a
--     -- miden-vm checkout so `std::..` / `miden::core::..` resolve.
--     extra_roots = { "~/work/miden-vm" },
--     -- Directory names never descended into while indexing.
--     ignore_dirs = { "target", "node_modules" },
--   }

local util = require("masm.util")
local project = require("masm.project")
local resolve = require("masm.resolve")

local M = {}

local uv = util.uv
local split_path = util.split_path
local strip_pub = util.strip_pub
local code_only = util.code_only
local code_text = util.code_text
local read_file = util.read_file

function M.clear_cache()
  project.clear_cache()
  -- :MasmRebuildIndex documents dropping "resolution caches" too; the
  -- content-keyed memos below can never be stale, but the command should
  -- do exactly what its docs say (masm.stack's clear_cache, invoked by the
  -- same command, drops its own memos likewise).
  resolve.clear_cache()
  util.clear_cache()
end

-- BufWritePost index-invalidation hook. The underscore name is load-bearing:
-- plugin/miden-masm.lua calls `package.loaded["masm.goto"]._file_written`
-- (the project index self-invalidates through it), so it stays exported here
-- under that exact name and delegates to masm.project.
---@param path string
function M._file_written(path)
  project.file_written(path)
end

-- Dialect-drift canary (see masm.resolve.unrecognized_imports); re-exported
-- here because masm.stackview reports the drift through this facade.
---@param text string
---@return {lnum: integer, text: string}[]
function M.unrecognized_imports(text)
  return resolve.unrecognized_imports(text)
end

---------------------------------------------------------------------------
-- Cursor context
---------------------------------------------------------------------------

local INVOKE_KINDS = { exec = true, call = true, syscall = true, procref = true }

-- Extracts the path-like token under the cursor plus context: the invocation
-- kind (`syscall.` targets resolve against the kernel library) and which
-- `::`-separated segment the cursor rests on (goto on a qualifier segment
-- jumps to the module file, not a symbol).
local function cursor_target()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] -- 0-based
  local s, e, token
  local init = 1
  while true do
    local ts, te = line:find(util.PATH_TOKEN, init)
    if not ts then
      return nil
    end
    if col < te then
      s, e, token = ts, te, line:sub(ts, te)
      break
    end
    init = te + 1
  end
  local kind, retargeted
  if INVOKE_KINDS[token] and line:sub(e + 1, e + 1) == "." then
    -- Cursor on `exec` itself: the target is the token after the dot.
    kind = token
    retargeted = true
    s = e + 2
    token = line:match("^" .. util.PATH_TOKEN, s)
    if not token then
      return nil
    end
  else
    kind = line:sub(1, s - 1):match("([%w_]+)%.$")
    if kind and not INVOKE_KINDS[kind] then
      kind = nil
    end
  end
  token = token:match("^:*(.-):*$") -- trim stray colons at the edges
  if token == "" then
    return nil
  end
  local segs = split_path(token)
  if #segs == 0 then
    return nil
  end
  -- Which segment is the cursor on? When the cursor sat on the `exec`
  -- keyword itself the target is the whole invocation, not a qualifier: the
  -- cursor offset lies before the retargeted token and would otherwise
  -- select segment 1 (the module) instead of the invoked name.
  local active = #segs
  if not retargeted then
    local off = math.max(col + 1 - s, 0)
    local pos = 0
    for i, seg in ipairs(segs) do
      pos = pos + #seg
      if off < pos + 2 then -- +2 tolerates the cursor sitting on the `::`
        active = i
        break
      end
      pos = pos + 2
    end
  end
  return { token = token, segs = segs, active = active, kind = kind, line = line }
end

-- How many lines around the cursor to search for the enclosing multi-line
-- `use { .. } from <mod>` statement. Real-world blocks run to ~20 lines; a
-- block larger than this window is not recognized from inside the braces.
local USE_BLOCK_WINDOW = 40

-- If the cursor sits inside a `use {..} from <mod>` statement (which may span
-- several lines), returns its parts and whether the cursor is in the braces.
local function use_statement_at_cursor()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local start = math.max(row - USE_BLOCK_WINDOW, 1)
  local lines = vim.api.nvim_buf_get_lines(0, start - 1, row + USE_BLOCK_WINDOW, false)
  local off = col -- 0-based offset of the cursor within the joined text
  for i = 1, row - start do
    off = off + #lines[i] + 1
  end
  for i, l in ipairs(lines) do
    lines[i] = code_only(l) -- same length; offsets stay valid
  end
  local text = table.concat(lines, "\n")
  local found
  resolve.each_selective_use(text, false, function(stmt)
    if not found and off >= stmt.start - 1 and off < stmt.stmt_end - 1 then
      found = {
        braces = stmt.braces,
        mod = stmt.mod,
        in_braces = off > stmt.brace_open - 1 and off < stmt.brace_close - 1,
      }
    end
  end)
  return found
end

---------------------------------------------------------------------------
-- Resolution
---------------------------------------------------------------------------

-- Context-sensitive resolution for the statement forms goto can start from.
local function resolve_at_cursor(index, buftext, bufpath)
  local t = cursor_target()
  if not t then
    return nil, "nothing under cursor"
  end
  local mods, syms = resolve.parse_imports(buftext)
  local stripped = strip_pub(t.line)

  -- `pub mod name` (mod.masm): open the submodule file next to this one.
  if stripped:match("^mod%s+" .. vim.pesc(t.token) .. util.IDENT_FRONTIER) then
    local dir = vim.fs.dirname(bufpath)
    for _, c in ipairs({ dir .. "/" .. t.token .. ".masm", dir .. "/" .. t.token .. "/mod.masm" }) do
      if util.file_exists(c) then
        return resolve.tag_item(t.token, c, 1, "module")
      end
    end
    return nil, "submodule file for " .. t.token .. " not found"
  end

  -- `use {..} from <mod>` statements, including multi-line ones.
  local stmt = use_statement_at_cursor()
  if stmt then
    local file = project.resolve_module(split_path(stmt.mod), index)
    if not file then
      return nil, "module " .. stmt.mod .. " not found"
    end
    if stmt.in_braces then
      local orig = t.token
      resolve.each_use_item(stmt.braces, function(o, a)
        if a == t.token then
          orig = o
          return true
        end
      end)
      local p, l = resolve.find_symbol(file, orig, index, 0)
      if p then
        return resolve.tag_item(t.token, p, l)
      end
      return nil, orig .. " not found in " .. stmt.mod
    end
    -- Cursor on the module path: jump to the module named by the segment
    -- under the cursor (a prefix segment resolves to its own module file).
    if t.token:find(":") then
      local prefix = vim.list_slice(t.segs, 1, t.active)
      local f = project.resolve_module(prefix, index)
      if f then
        return resolve.tag_item(t.segs[t.active], f, 1, "module")
      end
      return nil, "module " .. table.concat(prefix, "::") .. " not found"
    end
    return resolve.tag_item(vim.fs.basename(file), file, 1, "module")
  end

  -- Plain `use a::b` / `use a::b as x` lines: jump to the module file.
  if stripped:match("^use%f[^%w_]") then
    local prefix = vim.list_slice(t.segs, 1, t.active)
    if #prefix == 1 and mods[t.token] then
      prefix = mods[t.token] -- cursor on the alias name itself
    end
    local file = project.resolve_module(prefix, index)
    if file then
      return resolve.tag_item(t.segs[t.active], file, 1, "module")
    end
    return nil, "module " .. table.concat(prefix, "::") .. " not found"
  end

  return resolve.resolve_path(t.segs, t.active, t.kind, mods, syms, buftext, bufpath, index)
end

---------------------------------------------------------------------------
-- References
---------------------------------------------------------------------------

-- The set of line numbers covered by selective `use {..} from ..` statements
-- (which may span lines) in code-only text. Bare tokens on these lines are
-- import items -- one of the few positions where a symbol is spelled without
-- an invocation prefix.
local function selective_use_lines(code)
  local covered = {}
  local lnum_of = util.line_tracker(code)
  resolve.each_selective_use(code, false, function(stmt)
    local first = lnum_of(stmt.start)
    local last = first
    for _ in code:sub(stmt.start, stmt.stmt_end - 1):gmatch("\n") do
      last = last + 1
    end
    for l = first, last do
      covered[l] = true
    end
  end)
  return covered
end

-- Collects every usage in `text` (one file) that resolves to the definition
-- at (def_path, def_lnum) whose definition-site name is `def_name`. Renamed
-- re-exports are handled by resolving each candidate, not by name matching.
-- `add` receives (file, lnum, col, raw_line, spelled_name, name_col,
-- shadowable): `spelled_name` is the last path segment actually written at
-- the site and `name_col` its 1-based column -- rename() needs both to
-- rewrite exactly the sites that spell the definition name, leaving aliases
-- alone. `shadowable` is true for sites that resolve through the file's
-- LOCAL names (bare tokens): rewriting one into a file where the new name
-- already means something would silently change what it resolves to, which
-- is why rename refuses that (qualified `mod::name` and kernel-routed
-- `syscall.name` sites resolve elsewhere and cannot be shadowed).
local function collect_symbol_refs(f, text, def_path, def_lnum, def_name, index, add)
  local mods, syms = resolve.parse_imports(text)
  -- Local names in this file that resolve to the definition.
  local local_names = {}
  if f == def_path then
    local_names[def_name] = true
  end
  for alias, imp in pairs(syms) do
    local mf = project.resolve_module(imp.mod, index)
    if mf then
      local p, l = resolve.find_symbol(mf, imp.orig, index, 0)
      if p == def_path and l == def_lnum then
        local_names[alias] = true
      end
    end
  end

  local use_lines = selective_use_lines(code_text(text))
  local lnum = 0
  for raw in text:gmatch("([^\n]*)\n?") do
    lnum = lnum + 1
    local line = code_only(raw)
    -- On `const`/`type` declaration lines, everything right of the `=` is an
    -- expression over other constants/types (`const C = A + B`,
    -- `type P = struct { x: Pair }`).
    local decl_kw = strip_pub(line):match("^(%a+)%f[^%w_]")
    local decl_eq = (decl_kw == "const" or decl_kw == "type") and line:find("=", 1, true)
    for s, tok in line:gmatch("()(" .. util.PATH_TOKEN .. ")") do
      if tok:find(":") then
        local segs = split_path(tok)
        if #segs >= 2 then
          local prefix = resolve.expand_alias(vim.list_slice(segs, 1, #segs - 1), mods)
          local mf = project.resolve_module(prefix, index)
          if mf then
            local p, l = resolve.find_symbol(mf, segs[#segs], index, 0)
            if p == def_path and l == def_lnum then
              local name = segs[#segs]
              add(f, lnum, s, raw, name, s + #tok - #name, false)
            end
          end
        end
      elseif local_names[tok] then
        -- A token that merely EQUALS a resolvable name is not a reference:
        -- Miden's stdlib defines procs named `add`, `and`, `eq`, and the
        -- bare INSTRUCTION tokens spelling those mnemonics must never be
        -- collected -- rename would rewrite the opcodes themselves. Count
        -- the token only in positions where the dialect spells a symbol:
        --   * after a dot (`exec.add`, `push.MAX`, `mem_load.ADDR`)
        --   * after `=` (`assert.err=ERR_CODE`), or anywhere right of a
        --     `const`/`type` declaration's `=`
        --   * right after the defining keyword (`proc add` -- the site)
        --   * inside a `use {..} from ..` item list (import references)
        --   * on an `@attribute(..)` line (attribute arguments)
        local before = line:sub(1, s - 1)
        local kw = strip_pub(before):match("^(%a+)%s+$")
        if
          before:sub(-1) == "."
          or before:match("=%s*$")
          or (decl_eq and s > decl_eq)
          or kw == "proc"
          or kw == "const"
          or kw == "type"
          or use_lines[lnum]
          or line:match("^%s*@")
        then
          add(f, lnum, s, raw, tok, s, true)
        end
      elseif line:sub(1, s - 1):match("([%w_]+)%.$") == "syscall" then
        -- `syscall.name` needs no import; resolve against the kernel library.
        for _, lib in ipairs(index.libs) do
          if lib.kernel then
            local p, l = resolve.find_symbol(lib.root_file, tok, index, 0)
            if p == def_path and l == def_lnum then
              add(f, lnum, s, raw, tok, s, false)
            end
          end
        end
      end
    end
  end
end

-- Collects `use` statements in `text` whose module resolves to `def_path`.
local function collect_module_refs(f, text, def_path, index, add)
  local code = code_text(text) -- ignore use-statements in comments/strings
  local raw_lines
  -- each_selective_use yields statements in increasing offset order, so the
  -- line number can be tracked incrementally (see util.line_tracker).
  local lnum_of = util.line_tracker(code)
  resolve.each_selective_use(code, false, function(stmt)
    if project.resolve_module(split_path(stmt.mod), index) == def_path then
      raw_lines = raw_lines or vim.split(text, "\n")
      local l = lnum_of(stmt.start)
      add(f, l, 1, raw_lines[l] or "")
    end
  end)
  local lnum = 0
  for raw in text:gmatch("([^\n]*)\n?") do
    lnum = lnum + 1
    local l = strip_pub(code_only(raw))
    -- The alias is util.IDENT (`$`-inclusive) to match resolve.parse_imports;
    -- the path charset stays [%w_:] like every module-path pattern.
    local mod = l:match("^use%s+([%w_:]+)%s+as%s+" .. util.IDENT) or l:match("^use%s+([%w_:]+)%s*$")
    if mod and project.resolve_module(split_path(mod), index) == def_path then
      add(f, lnum, 1, raw)
    end
  end
end

---@class masm.ReferenceTarget the ground-truth definition a scan recognizes
---@field is_symbol boolean false when a module (file) was resolved
---@field def_path string definition file
---@field def_lnum integer definition line
---@field def_name string? definition-site name (symbols only)
---@field kw string? defining keyword ("proc"/"const"/"type"; symbols only)

-- Text for a scanned file: the live buffer when one is loaded (unsaved
-- edits must win everywhere -- for rename they MUST, or collected positions
-- would not match the buffer the edit lands in), disk otherwise. When
-- `ticks` is given, the changedtick of every buffer read is recorded in it
-- at the moment of the read -- the async references scan uses this to
-- detect buffers edited under an in-flight scan (see scan_stale).
---@param f string
---@param ticks table<integer, integer>?
local function file_text(f, ticks)
  local bufnr = util.loaded_bufnr(f)
  if bufnr then
    if ticks then
      ticks[bufnr] = vim.api.nvim_buf_get_changedtick(bufnr)
    end
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  end
  return read_file(f)
end

-- Resolves the cursor to a scan target: the ground-truth definition plus
-- what a project scan needs to recognize it. Returns
-- { is_symbol, def_path, def_lnum, def_name, kw } or nil and a reason.
---@return masm.ReferenceTarget? target
---@return string? reason
local function reference_target(index, buftext, bufpath)
  local res_ok, item, reason = pcall(resolve_at_cursor, index, buftext, bufpath)
  if not res_ok then
    return nil, tostring(item)
  end
  if not item then
    return nil, reason or "cannot resolve"
  end
  local target = {
    is_symbol = item.user_data ~= "module",
    def_path = item.filename,
    def_lnum = tonumber(item.cmd),
  }
  if target.is_symbol then
    -- def_lnum was resolved with live-buffer-wins semantics (the current
    -- buffer's possibly-unsaved text, or resolve.file_interface's preference
    -- for a modified loaded buffer); the def line must come from the same
    -- source, or unsaved edits above it would silently make the scan
    -- describe whatever symbol sits on that disk line instead.
    local def_text = (target.def_path == bufpath and buftext) or file_text(target.def_path) or ""
    local def_line = vim.split(def_text, "\n")[target.def_lnum] or ""
    target.kw, target.def_name = strip_pub(def_line):match("^(%a+)%s+(" .. util.IDENT .. ")")
    if not target.def_name then
      return nil, "no definition at " .. target.def_path .. ":" .. target.def_lnum
    end
  end
  return target
end

-- Cooperative scan driver. A references() scan visits every indexed file;
-- on a large project (or a miden-vm extra_root) that is hundreds of files,
-- and doing it in one go would freeze the UI thread for its duration.
-- Instead the scan runs in time slices and yields to the event loop between
-- them; `sync = true` (tests, rename) runs to completion in one call.
-- Starting a new scan cancels the one in flight.
local active_scan
local SCAN_SLICE_MS = 10
-- How many times a completed async scan is redone from scratch when a
-- buffer it read was edited mid-flight. One restart handles the realistic
-- case (the user typed while a big scan ran); the bound only guarantees a
-- pathological editing loop terminates in a warning instead of scanning
-- forever.
local MAX_SCAN_RESTARTS = 3

-- Test hook (see stackview's `_diag_ns` convention): the slice length is
-- otherwise an unreachable local, and the fixture project scans in well under
-- one 10ms slice, which would make the in-flight-cancellation path untestable.
-- tests/hardening_test.lua shrinks it so a scan needs several slices; nil
-- (always, outside tests) means SCAN_SLICE_MS.
M._scan_slice_ms = nil

local function run_scan(scan)
  local deadline = scan.sync and math.huge
    or (uv.hrtime() + (M._scan_slice_ms or SCAN_SLICE_MS) * 1e6)
  while scan.i <= #scan.files do
    if uv.hrtime() > deadline then
      vim.schedule(function()
        if not scan.cancelled then
          run_scan(scan)
        end
      end)
      return
    end
    local f = scan.files[scan.i]
    scan.i = scan.i + 1
    local text = file_text(f, scan.ticks)
    if text then
      -- One unreadable or pathological file must not kill the whole scan.
      if not pcall(scan.visit, f, text) then
        scan.errors = scan.errors + 1
      end
    end
  end
  if scan == active_scan then
    active_scan = nil
  end
  scan.on_done()
end

local function start_scan(scan)
  -- Cancel and forget any scan in flight: leaving `active_scan` pointing at
  -- a cancelled scan (as a sync preemption otherwise would) makes the next
  -- start_scan "cancel" a corpse.
  if active_scan then
    active_scan.cancelled = true
    active_scan = nil
  end
  if not scan.sync then
    active_scan = scan
  end
  scan.i = 1
  scan.errors = 0
  scan.ticks = {}
  run_scan(scan)
end

-- Whether any buffer the scan read was edited (or wiped) after the read.
-- Collected positions describe the text at read time; an async scan yields
-- to the event loop between slices, so user edits can shift lines under
-- items already collected -- a stale scan's results must not be published.
local function scan_stale(scan)
  for bufnr, tick in pairs(scan.ticks) do
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_buf_get_changedtick(bufnr) ~= tick then
      return true
    end
  end
  return false
end

-- Re-verifies that the target's definition line still declares its name --
-- shared by rename (an async prompt may have intervened between resolution
-- and application) and the references scan's stale-restart (a mid-scan edit
-- may have moved the definition itself).
---@param target masm.ReferenceTarget
local function target_current(target)
  if not target.is_symbol then
    return true
  end
  local def_line = vim.split(file_text(target.def_path) or "", "\n")[target.def_lnum] or ""
  return strip_pub(def_line):match("^%a+%s+(" .. util.IDENT .. ")") == target.def_name
end

local function sort_ref_items(items, target)
  table.sort(items, function(a, b)
    local a_def = a.filename == target.def_path and a.lnum == target.def_lnum
    local b_def = b.filename == target.def_path and b.lnum == target.def_lnum
    if a_def ~= b_def then
      return a_def -- the definition sorts first
    end
    if a.filename ~= b.filename then
      return a.filename < b.filename
    end
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    return a.col < b.col
  end)
end

-- Finds all references to the symbol (or module) under the cursor across the
-- indexed project and populates the quickfix list, definition first. The
-- scan is asynchronous (the quickfix list opens when it completes); pass
-- { sync = true } to block until done and get the items back.
---@param opts {sync: boolean?}?
---@return {filename: string, lnum: integer, col: integer, text: string}[]? items sync mode only; nil when empty
function M.references(opts)
  opts = opts or {}
  local bufpath = vim.api.nvim_buf_get_name(0)
  if bufpath == "" then
    return
  end
  local ok, index = pcall(project.build_index, bufpath)
  if not ok then
    vim.notify("masm references: indexing failed: " .. tostring(index), vim.log.levels.ERROR)
    return
  end
  local buftext = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  local target, reason = reference_target(index, buftext, bufpath)
  if not target then
    vim.notify("masm references: " .. reason, vim.log.levels.WARN)
    return
  end

  local items, seen = {}, {}
  local function add(f, lnum, col, text)
    local key = f .. ":" .. lnum .. ":" .. col
    if not seen[key] then
      seen[key] = true
      table.insert(items, { filename = f, lnum = lnum, col = col, text = vim.trim(text) })
    end
  end

  local scan
  scan = {
    files = index.masm,
    sync = opts.sync,
    visit = function(f, text)
      if target.is_symbol then
        collect_symbol_refs(f, text, target.def_path, target.def_lnum, target.def_name, index, add)
      else
        collect_module_refs(f, text, target.def_path, index, add)
      end
    end,
    on_done = function()
      -- An async scan interleaves with user input: when a buffer it read
      -- was edited before completion, redo the whole scan (fresh reads see
      -- the new text) rather than publish a mix of pre- and post-edit
      -- positions. Bounded; gives up loudly, never silently wrong.
      if not scan.sync and scan_stale(scan) then
        scan.restarts = (scan.restarts or 0) + 1
        if scan.restarts <= MAX_SCAN_RESTARTS and target_current(target) then
          items, seen = {}, {}
          start_scan(scan)
          return
        end
        vim.notify("masm references: buffers changed while scanning; rerun", vim.log.levels.WARN)
        return
      end
      if scan.errors > 0 then
        vim.notify(
          "masm references: failed to scan " .. scan.errors .. " file(s)",
          vim.log.levels.WARN
        )
      end
      sort_ref_items(items, target)
      if #items == 0 then
        vim.notify("masm references: no references found", vim.log.levels.WARN)
        return
      end
      local what = target.is_symbol and (target.kw .. " " .. target.def_name)
        or ("module " .. vim.fs.basename(target.def_path))
      vim.fn.setqflist({}, " ", { title = "MASM references: " .. what, items = items })
      vim.cmd("botright copen")
    end,
  }
  start_scan(scan)
  if opts.sync then
    return #items > 0 and items or nil
  end
end

---------------------------------------------------------------------------
-- Rename
---------------------------------------------------------------------------

-- Occurrences of `target.def_name` as the ORIGINAL side of `use { orig }` /
-- `use { orig as alias }` items whose chain resolves to the definition.
-- These are not references (the local name at the use sites is the alias)
-- but rename must rewrite them, or the import would break: renaming
-- MAX_VALUE leaves `use { MAX_VALUE as LIMIT }` pointing at nothing.
local function collect_import_item_edits(f, text, target, index, add)
  local code = code_text(text)
  local line_of = util.line_tracker(code)
  resolve.each_selective_use(code, false, function(stmt)
    local mf = project.resolve_module(split_path(stmt.mod), index)
    if not mf then
      return
    end
    for item_pos, item in stmt.braces:gmatch("()([^,]+)") do
      -- util.IDENT, so `use { $special as x }` originals rename too.
      local name_off, orig = item:match("()(" .. util.IDENT .. ")")
      if orig == target.def_name then
        local p, l = resolve.find_symbol(mf, orig, index, 0)
        if p == target.def_path and l == target.def_lnum then
          -- brace content index j sits at code index stmt.brace_open + j
          -- (brace_open is the `{` itself).
          local abs = stmt.brace_open + item_pos + name_off - 1
          local lnum, line_start = line_of(abs)
          -- An un-aliased item binds the original as the LOCAL name (the
          -- same `orig as alias` pattern each_use_item recognizes), so the
          -- rewritten name is shadowable; an aliased item keeps its alias.
          local aliased = item:match(util.IDENT .. "%s+as%s+" .. util.IDENT) ~= nil
          add(f, lnum, abs - line_start + 1, not aliased)
        end
      end
    end
  end)
end

-- Built from the canonical charset (util.IDENT): `$`-sigil names are legal
-- MASM identifiers and must be creatable by rename. Only a leading digit is
-- refused -- that spelling would read as a number at use sites.
local function valid_ident(name)
  return type(name) == "string"
    and name:match("^" .. util.IDENT .. "$") ~= nil
    and name:match("^%d") == nil
end

-- The scan-and-apply half of rename, split from the cursor-resolution half
-- so the vim.ui.input callback can pass the target CAPTURED at prompt time
-- (see M.rename). `bufpath` anchors the index build: rooting at the
-- definition instead would miss the caller's project when the definition
-- lives in an extra_root.
local function apply_rename(bufpath, target, new_name)
  if not valid_ident(new_name) then
    vim.notify("masm rename: invalid name " .. vim.inspect(new_name), vim.log.levels.WARN)
    return nil, "invalid name"
  end
  if new_name == target.def_name then
    vim.notify("masm rename: already named " .. new_name .. "; nothing to do", vim.log.levels.INFO)
    return nil, "same name"
  end
  local ok, index = pcall(project.build_index, bufpath)
  if not ok then
    return nil, "indexing failed: " .. tostring(index)
  end

  -- Time (an async prompt, at least) may have passed since the target was
  -- resolved: verify the definition line still declares that name, or the
  -- scan below would describe whatever now sits on it.
  if not target_current(target) then
    vim.notify(
      "masm rename: definition changed since it was resolved; aborted",
      vim.log.levels.WARN
    )
    return nil, "definition moved"
  end
  -- Collect edit positions: (file, lnum, 1-based col of the old name).
  -- `shadowed` accumulates files where a shadowable site (see
  -- collect_symbol_refs) would be rewritten while `new_name` already has a
  -- meaning in that file's scope -- applying such an edit would silently
  -- merge the two names (every old-name site would resolve to the
  -- survivor), so rename refuses below. Probed inside visit, on the text
  -- the scan already has in hand.
  local edits, seen, shadowed = {}, {}, {}
  local function add(f, lnum, col)
    local key = f .. ":" .. lnum .. ":" .. col
    if not seen[key] then
      seen[key] = true
      edits[f] = edits[f] or {}
      table.insert(edits[f], { lnum, col })
    end
  end
  -- Does `new_name` already mean something in this file's scope: its own
  -- definition, or an import binding it as the local name?
  local function name_taken(text)
    if resolve.find_def_line(text, new_name) then
      return true
    end
    local _, syms = resolve.parse_imports(text)
    return syms[new_name] ~= nil
  end
  local scan
  scan = {
    files = index.masm,
    sync = true,
    visit = function(f, text)
      local shadowable_here = false
      local function collect(sf, lnum, col, shadowable)
        shadowable_here = shadowable_here or shadowable == true
        add(sf, lnum, col)
      end
      collect_symbol_refs(
        f,
        text,
        target.def_path,
        target.def_lnum,
        target.def_name,
        index,
        function(sf, lnum, _, _, name, name_col, shadowable)
          if name == target.def_name then
            collect(sf, lnum, name_col, shadowable)
          end
        end
      )
      collect_import_item_edits(f, text, target, index, collect)
      if shadowable_here and name_taken(text) then
        shadowed[#shadowed + 1] = f
      end
    end,
    on_done = function() end,
  }
  start_scan(scan)
  if scan.errors > 0 then
    vim.notify(
      "masm rename: aborted, failed to scan " .. scan.errors .. " file(s)",
      vim.log.levels.ERROR
    )
    return nil, "scan failed"
  end
  if #shadowed > 0 then
    local where = vim.fs.basename(shadowed[1])
    if #shadowed > 1 then
      where = where .. (" and %d more file(s)"):format(#shadowed - 1)
    end
    vim.notify(
      "masm rename: " .. new_name .. " already has a meaning in " .. where .. "; aborted",
      vim.log.levels.WARN
    )
    return nil, "name collision"
  end

  -- Apply bottom-up so earlier edits cannot shift later positions, verifying
  -- the old name is still at each position (it was collected from this exact
  -- buffer/disk state, so a mismatch means a concurrent change: skip, count).
  -- 'shortmess' gains `A` for the duration: bufload of a file with a stale
  -- swap file must not block the whole rename on an interactive prompt.
  local old = target.def_name
  local applied, skipped, file_count = 0, 0, 0
  local shm = vim.o.shortmess
  vim.o.shortmess = shm .. "A"
  -- pcall so 'shortmess' is restored on EVERY path: an error mid-loop (a
  -- deleted buffer, a failed set_text) must not leave the `A` flag stuck for
  -- the rest of the session.
  local apply_ok, apply_err = pcall(function()
    for f, spots in pairs(edits) do
      table.sort(spots, function(a, b)
        if a[1] ~= b[1] then
          return a[1] > b[1]
        end
        return a[2] > b[2]
      end)
      local bufnr = vim.fn.bufadd(f)
      if not pcall(vim.fn.bufload, bufnr) then
        skipped = skipped + #spots
      else
        file_count = file_count + 1
        for _, s in ipairs(spots) do
          local lnum, col = s[1], s[2]
          local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
          if line:sub(col, col + #old - 1) == old then
            vim.api.nvim_buf_set_text(
              bufnr,
              lnum - 1,
              col - 1,
              lnum - 1,
              col - 1 + #old,
              { new_name }
            )
            applied = applied + 1
          else
            skipped = skipped + 1
          end
        end
      end
    end
  end)
  vim.o.shortmess = shm
  if not apply_ok then
    error(apply_err, 0)
  end

  local msg = ("masm rename: %s -> %s, %d occurrence(s) in %d file(s); buffers left unsaved (:wa to write)"):format(
    old,
    new_name,
    applied,
    file_count
  )
  if skipped > 0 then
    msg = msg .. ("; %d skipped (text changed)"):format(skipped)
  end
  vim.notify(msg, skipped > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
  return { applied = applied, skipped = skipped, files = file_count }
end

-- Renames the symbol under the cursor across the project: the definition,
-- every reference that spells the definition-site name (sites using an `as`
-- alias keep their alias -- that is the correct semantics, the alias still
-- resolves) and the original side of importing/re-exporting use-items.
-- Edits are applied to buffers and left unsaved for review (`:wa` writes
-- them); each buffer's undo history covers its own edits. Synchronous by
-- design: a scan racing user edits could write the new name into positions
-- that no longer hold the old one, and the applied-edit verification below
-- would then skip them.
---@param new_name string? prompted for via vim.ui.input when nil
---@return {applied: integer, skipped: integer, files: integer}? result nil on failure or when prompting
---@return string? reason
function M.rename(new_name)
  local bufpath = vim.api.nvim_buf_get_name(0)
  if bufpath == "" then
    return nil, "unnamed buffer"
  end
  local ok, index = pcall(project.build_index, bufpath)
  if not ok then
    return nil, "indexing failed: " .. tostring(index)
  end
  local buftext = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  local target, reason = reference_target(index, buftext, bufpath)
  if not target then
    vim.notify("masm rename: " .. reason, vim.log.levels.WARN)
    return nil, reason
  end
  if not target.is_symbol then
    vim.notify("masm rename: renames procs/consts/types, not modules", vim.log.levels.WARN)
    return nil, "not a symbol"
  end

  if new_name == nil then
    -- Pass the target RESOLVED NOW into the callback: vim.ui.input may be
    -- asynchronous (dressing.nvim, snacks), and by the time it fires the
    -- cursor can sit on a different symbol -- re-resolving there would
    -- silently rename that one instead.
    vim.ui.input({ prompt = "Rename " .. target.def_name .. " to: " }, function(input)
      if input and input ~= "" then
        apply_rename(bufpath, target, input)
      end
    end)
    return
  end
  return apply_rename(bufpath, target, new_name)
end

---------------------------------------------------------------------------
-- Document symbols
---------------------------------------------------------------------------

-- Lists the current buffer's top-level definitions (procs, consts, types,
-- submodules, entrypoint) in the location list.
---@return {bufnr: integer, lnum: integer, col: integer, text: string}[]? items nil when the buffer has none
function M.document_symbols()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local bufnr = vim.api.nvim_get_current_buf()
  local items = {}
  for i, line in ipairs(lines) do
    local l = strip_pub(line)
    if
      l:match("^proc%s+" .. util.IDENT_CHAR)
      or l:match("^const%s+" .. util.IDENT_CHAR)
      or l:match("^type%s+" .. util.IDENT_CHAR)
      or l:match("^mod%s+" .. util.IDENT_CHAR)
      or line:match("^begin%f[^%w_]") -- program entrypoint, not `begin_foo`
    then
      table.insert(items, {
        bufnr = bufnr,
        lnum = i,
        col = line:find("%S") or 1,
        text = vim.trim(line),
      })
    end
  end
  if #items == 0 then
    vim.notify("masm symbols: no definitions in this buffer", vim.log.levels.WARN)
    return
  end
  vim.fn.setloclist(0, {}, " ", { title = "MASM symbols", items = items })
  vim.cmd("lopen")
  return items
end

---------------------------------------------------------------------------
-- Entry points
---------------------------------------------------------------------------

-- Resolves the name under the cursor exactly as `gd` would, without jumping.
-- Returns the tag item ({ name, filename, cmd = lnum, user_data =
-- "symbol"|"module" }), or nil and a reason. Public: masm.hover builds on it,
-- and custom mappings can too.
---@return masm.TagItem? item
---@return string? reason
function M.resolve()
  local bufpath = vim.api.nvim_buf_get_name(0)
  if bufpath == "" then
    return nil, "unnamed buffer"
  end
  local ok, index = pcall(project.build_index, bufpath)
  if not ok then
    return nil, "indexing failed: " .. tostring(index)
  end
  local buftext = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  local res_ok, item, reason = pcall(resolve_at_cursor, index, buftext, bufpath)
  if not res_ok then
    return nil, tostring(item)
  end
  return item, reason
end

-- Builds a cursor-independent resolver over this buffer's imports and the
-- project index, for callers (masm.stack) that resolve many invocation
-- targets per pass: the index and import parse happen once here, each
-- returned call is then cache-backed. `kind` is the invocation keyword
-- ("exec"/"call"/"syscall"/"procref"); syscall targets resolve against the
-- kernel library exactly as cursor resolution would.
---@param bufpath string
---@param buftext string
---@return (fun(target: string, kind: string?): masm.TagItem?, string?)? resolver
---@return string? reason
function M.make_resolver(bufpath, buftext)
  -- Callers (masm.stack, tests) pass explicit paths that need not match how
  -- Neovim spells buffer names; canonicalize so index paths and same-file
  -- comparisons agree with the buffer side (see util.canonical).
  bufpath = util.canonical(bufpath)
  local ok, index = pcall(project.build_index, bufpath)
  if not ok then
    return nil, "indexing failed: " .. tostring(index)
  end
  local mods, syms = resolve.parse_imports(buftext)
  return function(target, kind)
    local token = target:match("^:*(.-):*$")
    if not token or token == "" then
      return nil, "empty target"
    end
    local segs = split_path(token)
    local res_ok, item, reason =
      pcall(resolve.resolve_path, segs, #segs, kind, mods, syms, buftext, bufpath, index)
    if not res_ok then
      return nil, tostring(item)
    end
    return item, reason
  end
end

-- The current buffer's import maps, for masm.complete: `mods` maps a local
-- qualifier to its module path segments, `syms` a local name to its
-- { mod = segments, orig = original name } import.
---@param buftext string
---@return table<string, string[]> mods
---@return table<string, {mod: string[], orig: string}> syms
function M.buffer_imports(buftext)
  return resolve.parse_imports(buftext)
end

-- The visible interface of module `segs` -- its own proc/const/type
-- definitions plus the names it re-exports -- as a sorted list of
-- { name, kind, path, lnum }. Cache-backed like navigation. Returns nil and
-- a reason when the module cannot be resolved.
---@param bufpath string
---@param segs string[]
---@return {name: string, kind: string?, path: string?, lnum: integer?}[]? symbols
---@return string? reason
function M.module_symbols(bufpath, segs)
  local ok, index = pcall(project.build_index, bufpath)
  if not ok then
    return nil, "indexing failed: " .. tostring(index)
  end
  local file = project.resolve_module(segs, index)
  if not file then
    return nil, "module " .. table.concat(segs, "::") .. " not found"
  end
  return resolve.interface_symbols(file, index)
end

-- The kernel library's interface (what `syscall.` targets resolve against).
---@param bufpath string
---@return {name: string, kind: string?, path: string?, lnum: integer?}[]? symbols
---@return string? reason
function M.kernel_symbols(bufpath)
  local ok, index = pcall(project.build_index, bufpath)
  if not ok then
    return nil, "indexing failed: " .. tostring(index)
  end
  for _, lib in ipairs(index.libs) do
    if lib.kernel then
      return resolve.interface_symbols(lib.root_file, index)
    end
  end
  return nil, "no kernel library in the project"
end

-- 'tagfunc' implementation. With the 'c' flag (normal-mode <C-]> / gd) the
-- cursor context drives resolution; otherwise `pattern` (from `:tag foo` or
-- tag completion) is parsed as a plain path.
---@param pattern string
---@param flags string
---@return masm.TagItem[]|vim.NIL items empty when nothing resolves
function M.tagfunc(pattern, flags, _)
  local bufpath = vim.api.nvim_buf_get_name(0)
  if bufpath == "" then
    return vim.NIL
  end
  local ok, index = pcall(project.build_index, bufpath)
  if not ok then
    return vim.NIL
  end
  local buftext = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")

  local item, reason
  if flags:find("c") then
    local res_ok
    res_ok, item, reason = pcall(resolve_at_cursor, index, buftext, bufpath)
    if not res_ok then
      vim.notify("masm goto: " .. tostring(item), vim.log.levels.ERROR)
      return {}
    end
  else
    -- `pattern` is user-typed (`:tag foo`): enforce the same identifier
    -- charset the cursor path guarantees, so path traversal characters and
    -- Lua-pattern magic never reach the resolver.
    if not pattern:match("^" .. util.PATH_TOKEN .. "$") then
      return {}
    end
    local segs = split_path(pattern)
    if #segs == 0 then
      return {}
    end
    local mods, syms = resolve.parse_imports(buftext)
    -- pcall like the cursor branch: an internal error must surface as "no
    -- tag found", not escape raw into the tag machinery.
    local res_ok
    res_ok, item, reason =
      pcall(resolve.resolve_path, segs, #segs, nil, mods, syms, buftext, bufpath, index)
    if not res_ok then
      vim.notify("masm goto: " .. tostring(item), vim.log.levels.ERROR)
      return {}
    end
  end

  if item then
    return { item }
  end
  if flags:find("c") and reason then
    vim.notify("masm goto: " .. reason, vim.log.levels.WARN)
  end
  return {}
end

return M
