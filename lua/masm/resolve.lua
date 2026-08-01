-- Use-statement parsing and symbol resolution for Miden Assembly. Split out
-- of masm.goto, which remains the public facade; masm.goto's cursor context,
-- references and rename all drive the machinery here.
--
-- Resolution is text-based, not tree-sitter-based, on purpose: the pinned
-- tree-sitter-masm grammar predates the current dialect and parses `use {..}
-- from ..`, `pub mod` and `use .. as ..` as ERROR nodes, which are exactly the
-- statements this module must understand.
--
-- Name resolution model (mirrors the Miden assembler):
--   * `use miden::foo::bar` imports module `bar`; `use .. as x` renames it;
--     `use {sym, orig as alias} from <module>` imports symbols directly.
--   * `exec.`/`call.`/`procref.` targets are `proc` names, local, imported or
--     qualified; `syscall.` targets live in the kernel library
--     (`[lib] kind = "kernel"`). `const` and `type` names resolve the same way.

local util = require("masm.util")
local project = require("masm.project")

local M = {}

local split_path = util.split_path
local strip_pub = util.strip_pub
local code_text = util.code_text

---@class masm.TagItem a resolution result in tagfunc item shape
---@field name string the resolved name as spelled at the query site
---@field filename string definition file
---@field cmd string definition line number as a string
---@field user_data '"symbol"'|'"module"' what was resolved

---@class masm.SelectiveUse positions and parts of a `use {..} from <mod>`
---@field start integer statement start offset in the scanned text
---@field brace_open integer offset of the `{`
---@field brace_close integer offset of the `}`
---@field braces string the text between the braces
---@field mod string the module path after `from`
---@field stmt_end integer offset just past the statement

---------------------------------------------------------------------------
-- Import parsing (works on raw text so ERROR nodes in the grammar are moot)
---------------------------------------------------------------------------

-- Iterates the `sym` / `orig as alias` items of a `use {..} from <mod>` list.
-- Stops early (and returns true) when `fn` returns true.
---@param braces string
---@param fn fun(orig: string, alias: string): boolean?
---@return boolean stopped
function M.each_use_item(braces, fn)
  -- util.IDENT, not a bare [%w_]+: `$`-sigil names are legal MASM
  -- identifiers and must be selectively importable (the charset invariant
  -- of util.IDENT_CHARS).
  for item in braces:gmatch("[^,]+") do
    local orig, alias = item:match("(" .. util.IDENT .. ")%s+as%s+(" .. util.IDENT .. ")")
    if not orig then
      orig = item:match("^%s*(" .. util.IDENT .. ")%s*$")
      alias = orig
    end
    if orig and fn(orig, alias) then
      return true
    end
  end
  return false
end

-- No real import list is this long; a longer "block" is an unclosed brace.
local USE_BRACES_MAX = 4096

-- Iterates `[pub] use { .. } from <mod>` statements in code-only text,
-- calling `fn` with a table of statement positions and parts. This is a
-- manual scan, NOT a `use%s*{([^}]*)}` gmatch, on purpose: with that
-- pattern, every unclosed `use {` re-scans to end-of-file, and a crafted
-- file of such lines costs O(occurrences x filesize) inside a single
-- uninterruptible Lua pattern call (~18 s for 140 KB). Here each candidate
-- does one bounded plain find, so the whole scan stays linear.
---@param code string code-only text (see util.code_text)
---@param pub_only boolean only `pub use` statements
---@param fn fun(stmt: masm.SelectiveUse)
function M.each_selective_use(code, pub_only, fn)
  -- Candidates come from a PLAIN find on the keyword, then an anchored
  -- match verifies the full statement shape at that position. A single
  -- frontier-first pattern (`%f[%w_]use%s*{`) would be equivalent but has
  -- no literal prefix for find() to skip with, so it probes every byte of
  -- the text -- measurably slow on large buffers. The `%f[%w_]` frontier is
  -- replaced by the explicit previous-character check: the keyword must not
  -- be the tail of a longer identifier like `my_use` (`%w_`, not `%w`,
  -- exactly as before).
  local lit = pub_only and "pub" or "use"
  local pat = pub_only and "^pub%s+use%s*{()" or "^use%s*{()"
  local init = 1
  while true do
    local s, brace_open, bpos
    while true do
      local u = code:find(lit, init, true)
      if not u then
        return
      end
      local prev = u > 1 and code:sub(u - 1, u - 1) or ""
      if prev == "" or not prev:match("[%w_]") then
        s, brace_open, bpos = code:find(pat, u)
        if s then
          break
        end
      end
      init = u + 1
    end
    -- The inner loop can only break with a successful anchored match, so
    -- both are set here; flow analysis cannot see across the break.
    ---@cast s integer
    ---@cast brace_open integer
    local close = code:find("}", bpos, true)
    if not close then
      return -- unclosed brace: everything after is inside it, nothing to find
    end
    if close - bpos <= USE_BRACES_MAX then
      local braces = code:sub(bpos, close - 1)
      local mod, stmt_end = code:match("^%s*from%s+([%w_:]+)()", close + 1)
      if mod then
        fn({
          start = s,
          brace_open = brace_open,
          brace_close = close,
          braces = braces,
          mod = mod,
          stmt_end = stmt_end,
        })
      end
    end
    init = close + 1
  end
end

-- The accepted single-line `use` forms, shared between parse_imports (which
-- consumes the captures) and unrecognized_imports' drift canary (which only
-- needs the match): one definition means the two cannot drift apart. Alias
-- positions use util.IDENT (`$`-inclusive); the module-path charset stays
-- [%w_:] deliberately -- it matches whole paths. All three are anchored at
-- both ends: a `use` line with trailing junk is not an import, it is drift
-- for the canary to report.
local USE_AS = "^use%s+([%w_:]+)%s+as%s+(" .. util.IDENT .. ")%s*$"
-- Legacy arrow-alias form from the pre-`as` dialect (the pinned tree-sitter
-- grammar's import_alias rule still spells it this way).
local USE_ARROW = "^use%s+([%w_:]+)%s*%-%>%s*(" .. util.IDENT .. ")%s*$"
local USE_PLAIN = "^use%s+([%w_:]+)%s*$"

-- Collects the import maps of a buffer's text:
--   mods:  local qualifier -> module path segments   (use a::b [as x])
--   syms:  local name -> { mod = segments, orig = original name }
---@param text string
---@return table<string, string[]> mods
---@return table<string, {mod: string[], orig: string}> syms
function M.parse_imports(text)
  local mods, syms = {}, {}
  -- Scan code only: a `use` statement quoted in a comment or an error string
  -- must not register an import.
  text = code_text(text)
  -- Selective imports may span lines: `use {\n  a,\n  b,\n} from path`.
  M.each_selective_use(text, false, function(stmt)
    local mod_segs = split_path(stmt.mod)
    M.each_use_item(stmt.braces, function(orig, alias)
      syms[alias] = { mod = mod_segs, orig = orig }
    end)
  end)
  -- Only lines containing a `use` substring can match the anchored forms
  -- below (strip_pub cannot introduce one), so instead of iterating every
  -- line, jump from occurrence to occurrence with plain finds (C-speed)
  -- and materialize just the containing line. `init = le + 1` both skips
  -- to the next line and processes each line at most once, exactly like
  -- the per-line loop this replaces.
  local n = #text
  local init = 1
  while true do
    local u = text:find("use", init, true)
    if not u then
      break
    end
    local le = text:find("\n", u, true) or (n + 1)
    local ls = u
    while ls > 1 and text:byte(ls - 1) ~= 10 do
      ls = ls - 1
    end
    local l = strip_pub(text:sub(ls, le - 1))
    local mod, alias = l:match(USE_AS)
    if not mod then
      mod, alias = l:match(USE_ARROW)
    end
    if not mod then
      mod = l:match(USE_PLAIN)
      if mod then
        local segs = split_path(mod)
        alias = segs[#segs]
      end
    end
    if mod and alias then
      mods[alias] = split_path(mod)
    end
    init = le + 1
  end
  return mods, syms
end

-- Dialect-drift canary. Resolution is text-based against the import forms
-- the current MASM dialect uses; a future dialect could add a form these
-- patterns miss, and the failure mode would be silent (imports simply not
-- seen, navigation and stack analysis quietly degraded). This scan makes
-- that loud: any code line that starts a `use` statement but matches none of
-- the recognized forms is reported, so drift surfaces as a diagnostic on the
-- offending line instead of as mysterious "not found" answers later.
-- Returns a list of { lnum, text }.
---@param text string
---@return {lnum: integer, text: string}[]
function M.unrecognized_imports(text)
  local code = code_text(text)
  -- Line numbers of recognized selective `use {..} from ..` statements: the
  -- opening line is the one that would otherwise look unrecognized (its
  -- continuation lines never start with `use`).
  local covered = {}
  local lnum_of = util.line_tracker(code)
  M.each_selective_use(code, false, function(stmt)
    covered[lnum_of(stmt.start)] = true
  end)
  local out = {}
  -- Occurrence-jumping scan, same reasoning as parse_imports; the second
  -- line_tracker maps each occurrence's line start to its line number
  -- (occurrences arrive in increasing offset order, as the tracker needs).
  local track = util.line_tracker(code)
  local n = #code
  local init = 1
  while true do
    local u = code:find("use", init, true)
    if not u then
      break
    end
    local le = code:find("\n", u, true) or (n + 1)
    local ls = u
    while ls > 1 and code:byte(ls - 1) ~= 10 do
      ls = ls - 1
    end
    local raw = code:sub(ls, le - 1)
    local lnum = track(ls)
    local l = strip_pub(raw)
    if l:match("^use%f[^%w_]") and not covered[lnum] then
      -- The exact patterns parse_imports accepts, so a parsed import is
      -- never reported as drift (and vice versa).
      local recognized = l:match(USE_AS)
        or l:match(USE_ARROW)
        or l:match(USE_PLAIN)
        -- The opening line of a selective use whose braces close on a LATER
        -- line: covered[] only has statements whose braces closed; an
        -- unclosed-because-still-being-typed block should not flap between
        -- states as the user types, so the opening shape alone passes here.
        -- A block left truly unterminated still surfaces: its `from` line
        -- never parses and resolution reports the import as missing.
        or l:match("^use%s*{")
      if not recognized then
        out[#out + 1] = { lnum = lnum, text = vim.trim(raw) }
      end
    end
    init = le + 1
  end
  return out
end

---------------------------------------------------------------------------
-- Symbol lookup inside a module file
---------------------------------------------------------------------------

-- Finds the definition line of `name` (a proc, const or type) in `text`.
--
-- Memoized as a one-pass name -> line map keyed on the text itself: every
-- unqualified lookup in a stack-analysis pass (`exec.local_proc`, every
-- `push.LOCAL_CONST`) lands here with the same buffer text, and a per-name
-- rescan of a 500 KB buffer times hundreds of lookups dominated the
-- analyzer's profile. Lua interns strings, so the table lookup is O(1). The
-- map records the FIRST `proc`/`const`/`type` definition of each name --
-- exactly what the per-name top-down scan returned: the generic identifier
-- capture and the old `name .. IDENT_FRONTIER` pattern accept the same
-- maximal identifier token. Bounded like every other cache (the bound only
-- caps how much text is retained; the map itself is pure).
local def_map_cache
local function def_map(text)
  def_map_cache = def_map_cache or util.new_cache(16)
  local map = def_map_cache:get(text)
  if map then
    return map
  end
  map = {}
  -- One occurrence-jumping scan per keyword (plain finds are C-speed and
  -- definition lines are sparse), instead of examining every line. Each
  -- candidate line is verified with the same strip_pub + line-anchored
  -- keyword match as before; "first definition wins" becomes an explicit
  -- min over line numbers because the three scans no longer see lines in
  -- one interleaved order.
  local n = #text
  for _, kw in ipairs({ "proc", "const", "type" }) do
    local pat = "^" .. kw .. "%s+(" .. util.IDENT .. ")"
    local track = util.line_tracker(text)
    local init = 1
    while true do
      local u = text:find(kw, init, true)
      if not u then
        break
      end
      local le = text:find("\n", u, true) or (n + 1)
      local ls = u
      while ls > 1 and text:byte(ls - 1) ~= 10 do
        ls = ls - 1
      end
      local name = strip_pub(text:sub(ls, le - 1)):match(pat)
      if name then
        local lnum = track(ls)
        if not map[name] or lnum < map[name] then
          map[name] = lnum
        end
      end
      init = le + 1
    end
  end
  def_map_cache:put(text, map)
  return map
end

---@param text string
---@param name string
---@return integer? lnum
function M.find_def_line(text, name)
  return def_map(text)[name]
end

-- Drops the content-keyed definition-map memo. Content keys can never go
-- stale; this exists so :MasmRebuildIndex's "drops resolution caches"
-- contract holds literally (masm.goto's clear_cache calls it).
function M.clear_cache()
  if def_map_cache then
    def_map_cache:clear()
  end
end

---@class masm.FileInterface a file's parsed interface, freshness-keyed
---@field key string freshness key at parse time (util.stat_key)
---@field bufnr integer|false loaded buffer named `path` at last use; false = none
---@field defs table<string, integer> definition name -> line number
---@field kinds table<string, string> definition name -> "proc"|"const"|"type"
---@field reexports {mod: string, items: {orig: string, alias: string}[]}[]

-- A file's parsed interface -- its definitions as a name -> line map plus
-- its `pub use` re-export statements -- built in ONE pass over the file and
-- cached under its freshness key. This is what keeps references() linear:
-- resolving N distinct names against the same module must not re-read and
-- re-scan that module N times (measured: ~10 ms per scan of a 130 KB file,
-- so a per-name re-scan turned 2000 names into ~20 s of frozen UI).
--
-- A MODIFIED loaded buffer wins over the disk file (unsaved edits must be
-- seen -- most visibly, navigation must follow a just-applied rename while
-- its edits sit unsaved for review); its freshness key is the changedtick,
-- since a disk mtime cannot see buffer edits. A clean buffer stays on the
-- disk path: its content matches the file it was read from, and the disk
-- may since have moved on (out-of-editor edits must keep tracking, which
-- the stale-cache tests pin). The two key formats cannot collide, so
-- sym_cache entries validated through this key re-resolve on either kind
-- of change.
--
-- FINDING that buffer is the expensive part: util.loaded_bufnr walks every
-- buffer (two API calls each), and paying that on every cache hit made hit
-- cost scale with the session's buffer count (measured 7.9x on warm
-- resolution with ~200 unrelated buffers open; scripts/bench.lua asserts on
-- the ratio now). So each entry remembers the buffer it last saw -- or
-- `false` for "none" -- and a hit revalidates that cheaply: a remembered
-- buffer still valid, loaded and named `path` IS the buffer, because Neovim
-- forbids two buffers sharing a name; a remembered "none" is reconfirmed by
-- bufloaded(), an exact-name lookup at C speed (never bufnr()'s pattern
-- matching -- see util.loaded_bufnr). Only when either answer changed (the
-- buffer was wiped or renamed, or a buffer for `path` appeared) does the
-- full walk run again.
---@param path string
---@param index masm.ProjectIndex
---@return masm.FileInterface
function M.file_interface(path, index)
  local entry = index.file_cache:get(path)
  local bufnr
  local b = entry and entry.bufnr
  if
    b
    and vim.api.nvim_buf_is_valid(b)
    and vim.api.nvim_buf_is_loaded(b)
    and vim.api.nvim_buf_get_name(b) == path
  then
    bufnr = b
  elseif b == false and vim.fn.bufloaded(path) == 0 then
    -- bufloaded, not bufexists: a :bdelete'd buffer still EXISTS (unloaded),
    -- and bufexists == 1 for it would demote every later hit to the full
    -- walk -- permanently, since the walk keeps re-finding "none". Loaded-ness
    -- is the exact property util.loaded_bufnr tests, at the same exact-name
    -- C-speed lookup as bufexists.
    bufnr = nil
  else
    bufnr = util.loaded_bufnr(path)
  end
  -- Remember what the walk (or revalidation) found, independent of the
  -- modified state: a clean buffer must stay remembered so its later edits
  -- are seen without another walk.
  local found = bufnr or false
  if bufnr and not vim.bo[bufnr].modified then
    bufnr = nil
  end
  local key
  if bufnr then
    key = "b:" .. bufnr .. ":" .. vim.api.nvim_buf_get_changedtick(bufnr)
  else
    key = util.stat_key(path) or "?"
  end
  if entry and entry.key == key then
    entry.bufnr = found
    return entry
  end
  entry = { key = key, bufnr = found, defs = {}, kinds = {}, reexports = {} }
  local text
  if bufnr then
    text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  else
    text = util.read_file(path)
  end
  if text then
    local lnum = 0
    for line in text:gmatch("([^\n]*)\n?") do
      lnum = lnum + 1
      local l = strip_pub(line)
      local kw, name = l:match("^(%a+)%s+(" .. util.IDENT .. ")")
      if (kw == "proc" or kw == "const" or kw == "type") and not entry.defs[name] then
        entry.defs[name] = lnum
        entry.kinds[name] = kw
      end
    end
    -- Only `pub use` re-exports a name; private imports are not interface.
    M.each_selective_use(code_text(text), true, function(stmt)
      local items = {}
      M.each_use_item(stmt.braces, function(orig, alias)
        items[#items + 1] = { orig = orig, alias = alias }
      end)
      entry.reexports[#entry.reexports + 1] = { mod = stmt.mod, items = items }
    end)
  end
  index.file_cache:put(path, entry)
  return entry
end

-- Re-export chains longer than this report "not found" rather than resolving
-- (documented in the Limitations sections). Real-world chains are 2-3 hops.
local MAX_REEXPORT_DEPTH = 5

-- Finds `name` in the module file `path`, following `pub use` re-export
-- chains (e.g. miden::protocol::note re-exports tx_kernel_core procs).
-- Returns the definition's file, line, and definition-site name (which may
-- differ from `name` when a re-export renamed it).
--
-- The `visited` map bounds one resolution to the number of distinct
-- (file, name) pairs (times the depth cap): without it, N same-alias
-- re-export items per file multiply at every hop and a small crafted file
-- pair costs N^depth -- an uninterruptible UI-thread hang. It also breaks
-- re-export cycles. Storing the depth (not just a flag) lets a shallower
-- later branch retry a pair first reached near the depth cap, so results
-- don't depend on statement order.
--
-- Results are memoized on the index as (def file, def name), never a line
-- number: the line is re-derived from the freshness-keyed file_interface on
-- every hit, so edits to the defining file cannot yield stale jump targets.
-- Each entry also carries the freshness keys of EVERY file the resolution
-- consulted (the `visited` set), and a hit is honored only while all of them
-- are unchanged: retargeting a `pub use` in the MIDDLE of a chain, or adding
-- an export to an intermediate file an earlier search walked through, must
-- re-resolve -- keying on the origin file alone served stale targets in both
-- cases. Negative results are cached only for complete (depth-0) searches,
-- so a search truncated by the depth cap cannot poison a later, shallower
-- one.

-- The distinct files of a resolution's `visited` set, with their current
-- freshness keys. Every one of them was consulted, so a change to any can
-- change the result (an earlier-failing re-export branch may now succeed
-- and shadow a later one).
local function visited_deps(visited, index)
  local deps = {}
  for vkey in pairs(visited) do
    local f = vkey:match("^(.-)\1")
    if f and not deps[f] then
      deps[f] = M.file_interface(f, index).key
    end
  end
  return deps
end

local function deps_fresh(deps, index)
  for f, k in pairs(deps) do
    if M.file_interface(f, index).key ~= k then
      return false
    end
  end
  return true
end

---@param path string module file to search
---@param name string symbol name as spelled at the query site
---@param index masm.ProjectIndex
---@param depth integer re-export recursion depth (0 at the query site)
---@param visited table<string, integer>? (file, name) -> shallowest depth seen
---@return string? def_path
---@return integer? def_lnum
---@return string? def_name definition-site name (may differ via `as` renames)
function M.find_symbol(path, name, index, depth, visited)
  if depth > MAX_REEXPORT_DEPTH then
    return nil
  end
  local key = path .. "\1" .. name
  visited = visited or {}
  if visited[key] and visited[key] <= depth then
    return nil
  end
  visited[key] = depth

  local iface = M.file_interface(path, index)
  -- Cache entries: { neg = true, deps } is a negative result, { def file,
  -- def name, deps } a positive one. `deps` maps every consulted file to the
  -- freshness key it had at resolution time; either kind is honored only
  -- while all of them are unchanged ("write the call site, gd fails, write
  -- the proc, gd works" behaves, and so does editing any intermediate hop).
  local src = iface.key
  local hit = index.sym_cache:get(key)
  if hit ~= nil then
    if not deps_fresh(hit.deps, index) then
      index.sym_cache:put(key, nil)
    elseif hit.neg then
      return nil
    else
      local lnum = M.file_interface(hit[1], index).defs[hit[2]]
      if lnum then
        return hit[1], lnum, hit[2]
      end
      index.sym_cache:put(key, nil) -- definition moved away; re-resolve below
    end
  end

  local lnum = iface.defs[name]
  if lnum then
    index.sym_cache:put(key, { path, name, deps = { [path] = src } })
    return path, lnum, name
  end
  for _, re in ipairs(iface.reexports) do
    for _, it in ipairs(re.items) do
      if it.alias == name then
        local f = project.resolve_module(split_path(re.mod), index)
        if f then
          local p, l, dn = M.find_symbol(f, it.orig, index, depth + 1, visited)
          if p then
            index.sym_cache:put(key, { p, dn, deps = visited_deps(visited, index) })
            return p, l, dn
          end
        end
      end
    end
  end
  if depth == 0 then
    index.sym_cache:put(key, { neg = true, deps = visited_deps(visited, index) })
  end
end

---------------------------------------------------------------------------
-- Path resolution
---------------------------------------------------------------------------

-- `kind` ("symbol" or "module") rides along in the tag item's user_data
-- field so references() knows what was resolved without re-deriving it.
---@param name string
---@param path string
---@param lnum integer?
---@param kind ('"symbol"'|'"module"')?
---@return masm.TagItem
function M.tag_item(name, path, lnum, kind)
  return { name = name, filename = path, cmd = tostring(lnum or 1), user_data = kind or "symbol" }
end

-- Expands a leading module alias: `asset_utils::x` -> `miden::protocol_utils::asset::x`.
---@param segs string[]
---@param mods table<string, string[]>
---@return string[]
function M.expand_alias(segs, mods)
  local target = mods[segs[1]]
  if not target then
    return segs
  end
  local full = vim.list_extend({}, target)
  for i = 2, #segs do
    table.insert(full, segs[i])
  end
  return full
end

-- Resolves a (possibly qualified) name against the index and the current
-- buffer's imports. Returns a tag item, or nil and a reason string.
---@param segs string[] path segments of the queried token
---@param active integer the segment the cursor rests on
---@param kind string? invocation keyword ("exec"/"call"/"syscall"/"procref")
---@param mods table<string, string[]> buffer import map (parse_imports)
---@param syms table<string, {mod: string[], orig: string}> selective imports
---@param buftext string current buffer text
---@param bufpath string current buffer path
---@param index masm.ProjectIndex
---@return masm.TagItem? item
---@return string? reason
function M.resolve_path(segs, active, kind, mods, syms, buftext, bufpath, index)
  -- Cursor on a qualifier segment: jump to that module's file.
  if active < #segs then
    local prefix = M.expand_alias(vim.list_slice(segs, 1, active), mods)
    local file = project.resolve_module(prefix, index)
    if file then
      return M.tag_item(segs[active], file, 1, "module")
    end
    return nil, "module " .. table.concat(prefix, "::") .. " not found"
  end

  local name = segs[#segs]

  if #segs == 1 then
    -- `syscall.name` targets the kernel library.
    if kind == "syscall" then
      for _, lib in ipairs(index.libs) do
        if lib.kernel then
          local p, l = M.find_symbol(lib.root_file, name, index, 0)
          if p then
            return M.tag_item(name, p, l)
          end
        end
      end
      return nil, "kernel procedure " .. name .. " not found"
    end
    -- Definition in the current file.
    local lnum = M.find_def_line(buftext, name)
    if lnum then
      return M.tag_item(name, bufpath, lnum)
    end
    -- Symbol imported via `use {..} from ..`.
    local imp = syms[name]
    if imp then
      local file = project.resolve_module(imp.mod, index)
      if not file then
        return nil, "module " .. table.concat(imp.mod, "::") .. " not found"
      end
      local p, l = M.find_symbol(file, imp.orig, index, 0)
      if p then
        return M.tag_item(name, p, l)
      end
      return nil, imp.orig .. " not found in " .. table.concat(imp.mod, "::")
    end
    -- A module qualifier on its own (e.g. the cursor on `x` of `use a::b as x`
    -- elsewhere in the file).
    if mods[name] then
      local file = project.resolve_module(mods[name], index)
      if file then
        return M.tag_item(name, file, 1, "module")
      end
    end
    return nil, "no definition or import of " .. name .. " in this file"
  end

  -- Qualified: `qualifier::name` or a full `a::b::name` path.
  local mod_segs = M.expand_alias(vim.list_slice(segs, 1, #segs - 1), mods)
  local file = project.resolve_module(mod_segs, index)
  if not file then
    return nil, "module " .. table.concat(mod_segs, "::") .. " not found"
  end
  local p, l = M.find_symbol(file, name, index, 0)
  if p then
    return M.tag_item(name, p, l)
  end
  return nil, name .. " not found in " .. table.concat(mod_segs, "::")
end

---------------------------------------------------------------------------
-- Module interfaces
---------------------------------------------------------------------------

-- The visible interface of the module file: its own proc/const/type
-- definitions plus the names it re-exports, as a sorted list of
-- { name, kind, path, lnum }.
---@param file string
---@param index masm.ProjectIndex
---@return {name: string, kind: string?, path: string?, lnum: integer?}[]
function M.interface_symbols(file, index)
  local iface = M.file_interface(file, index)
  local out, seen = {}, {}
  for name, lnum in pairs(iface.defs) do
    out[#out + 1] = { name = name, kind = iface.kinds[name], path = file, lnum = lnum }
    seen[name] = true
  end
  -- Re-exported names resolve through the same chain navigation uses; kind
  -- and location come from the ground-truth definition. An unresolvable
  -- re-export is still offered by name (kind unknown): the name is visibly
  -- part of the module's interface even when its source is not indexed.
  for _, re in ipairs(iface.reexports) do
    for _, it in ipairs(re.items) do
      if not seen[it.alias] then
        seen[it.alias] = true
        local p, l, dn = M.find_symbol(file, it.alias, index, 0)
        local kind = p and M.file_interface(p, index).kinds[dn] or nil
        out[#out + 1] = { name = it.alias, kind = kind, path = p, lnum = l }
      end
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

return M
