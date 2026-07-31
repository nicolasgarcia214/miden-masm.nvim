-- Shared low-level helpers for the miden-masm.nvim modules: hardened file
-- access, comment/string blanking, MASM path splitting, the canonical
-- identifier charset and small cache plumbing. Everything here is
-- deliberately free of project/index knowledge -- masm.project, masm.resolve,
-- masm.goto, masm.stack, masm.hover and masm.complete all build on it.

local M = {}

-- vim.uv is the 0.10+ name; vim.loop the pre-0.10 one. Alias once here so
-- every module agrees (a bare `vim.uv` would crash on older builds).
M.uv = vim.uv or vim.loop

---------------------------------------------------------------------------
-- Identifier charset
---------------------------------------------------------------------------

-- The ONE identifier charset for MASM names, `$`-inclusive: the grammar
-- allows `$` sigils (the `$exec` / `$kernel` markers, and `$`-prefixed
-- procedure names). Historically some scanners dropped the `$` and disagreed
-- with each other; every identifier pattern must be built from these.
M.IDENT_CHARS = "%w_%$"
-- One identifier character.
M.IDENT_CHAR = "[" .. M.IDENT_CHARS .. "]"
-- One identifier token.
M.IDENT = M.IDENT_CHAR .. "+"
-- One `::`-qualified path token (identifier segments and their separators).
M.PATH_TOKEN = "[" .. M.IDENT_CHARS .. ":]+"
-- End-of-identifier frontier. `%f[^..]`, not `%f[%W]`: Lua's %w excludes `_`
-- (and `$`), so the latter would let `add` match the definition of
-- `add_checked`.
M.IDENT_FRONTIER = "%f[^" .. M.IDENT_CHARS .. "]"

---------------------------------------------------------------------------
-- MASM path and line helpers
---------------------------------------------------------------------------

-- Splits `a::b::c` into segments. A single `:` is not a MASM path separator
-- (the assembler rejects `a:b`); treating it as one would happily resolve
-- code that does not compile, so malformed paths yield zero segments and
-- resolution reports "not found" downstream.
---@param path string
---@return string[] segs empty when the path is malformed
function M.split_path(path)
  if path:gsub("::", ""):find(":", 1, true) then
    return {}
  end
  local segs = {}
  for seg in path:gmatch("[^:]+") do
    table.insert(segs, seg)
  end
  return segs
end

-- Strips leading whitespace and a `pub ` modifier, so definition patterns can
-- anchor on the keyword.
---@param line string
---@return string
function M.strip_pub(line)
  return (line:gsub("^%s*", ""):gsub("^pub%s+", ""))
end

-- Reduces a line to scannable code, preserving its length and therefore every
-- token position: string-literal contents are blanked (a constant name inside
-- an error message is not a reference, and `use` statements inside strings or
-- comments must not register as imports) and `# ..` comments are blanked,
-- honoring `#` and `\"` escapes inside strings.
---@param line string
---@return string
function M.code_only(line)
  -- Fast paths first: the analyzer blanks every line of the buffer on each
  -- refresh, and the char-by-char state machine below dominated its profile.
  -- String literals are rare in real .masm (error messages only), so almost
  -- every line is either comment-free (returned as-is) or has a `#` before
  -- any `"` (prefix + space-fill). Only a line whose first `"` precedes its
  -- first `#` can need the escape-aware state machine.
  local hash = line:find("#", 1, true)
  local quote = line:find('"', 1, true)
  if not quote or (hash and hash < quote) then
    if not hash then
      return line
    end
    return line:sub(1, hash - 1) .. string.rep(" ", #line - hash + 1)
  end
  -- Slow path (a string literal opens before any comment): walk SEGMENTS
  -- with find instead of bytes with sub. Outside a string, copy verbatim up
  -- to the next `"` or `#`; a `#` blanks the rest of the line; inside a
  -- string, blank up to the closing quote, where a `\` escape consumes (and
  -- blanks) the following character so an escaped `"` cannot close.
  local out, pos, n = {}, 1, #line
  while pos <= n do
    local q = line:find('[#"]', pos)
    if not q then
      out[#out + 1] = line:sub(pos)
      break
    end
    out[#out + 1] = line:sub(pos, q - 1)
    if line:sub(q, q) == "#" then
      out[#out + 1] = string.rep(" ", n - q + 1)
      break
    end
    out[#out + 1] = " " -- the opening quote
    pos = q + 1
    while pos <= n do
      local e = line:find('[\\"]', pos)
      if not e then
        out[#out + 1] = string.rep(" ", n - pos + 1)
        pos = n + 1
        break
      end
      out[#out + 1] = string.rep(" ", e - pos + 1)
      if line:sub(e, e) == '"' then
        pos = e + 1
        break
      end
      if e < n then
        out[#out + 1] = " " -- the escaped character
      end
      pos = e + 2
    end
  end
  return table.concat(out)
end

-- Whole-text variant of code_only, applied line-wise so line numbers and
-- per-line offsets are preserved.
--
-- Memoized: one stack-analysis refresh blanks the same buffer text from
-- several independent call sites (import parsing, symbol resolution, the
-- dialect-drift canary), and callers pass the identical string each time.
-- Lua interns strings (a string key's hash is computed once, at creation),
-- so keying a table on the full text is O(1); memoizing dedupes the whole
-- refresh without touching any call-site signature. The cache is small but
-- larger than one entry on purpose: mid-pass cross-FILE resolution also
-- blanks callee texts, and a single-entry memo would be clobbered before
-- the buffer's own text is asked for again. Pure function, so memoization
-- can never change a result; the bound only caps how much text is retained.
local code_text_memo
---@param text string
---@return string
function M.code_text(text)
  code_text_memo = code_text_memo or M.new_cache(8)
  local hit = code_text_memo:get(text)
  if hit then
    return hit
  end
  local out = {}
  for line in text:gmatch("([^\n]*)\n?") do
    out[#out + 1] = M.code_only(line)
  end
  local res = table.concat(out, "\n")
  code_text_memo:put(text, res)
  return res
end

-- Seeds the code_text memo from an already-blanked line array: the stack
-- analyzer blanks per line for its own scan, and this spares the immediate
-- code_text(concat(lines)) calls of the same refresh a second whole-buffer
-- pass. The seeded value must reproduce code_text's exact output shape:
-- its line iterator yields one final empty match when the text does not
-- end in a newline, so the joined result carries one trailing newline in
-- that case (an invariant shared with code_text's loop above -- change one,
-- change both).
---@param text string the raw text, exactly as code_text would receive it
---@param code_lines string[] M.code_only of each of text's lines, in order
function M.prime_code_text(text, code_lines)
  code_text_memo = code_text_memo or M.new_cache(8)
  local res = table.concat(code_lines, "\n")
  if #text > 0 and text:sub(-1) ~= "\n" then
    res = res .. "\n"
  end
  code_text_memo:put(text, res)
end

-- Drops util's own memo (the blanked-text cache above). Content-keyed, so
-- it can never serve stale data -- this exists because :MasmRebuildIndex
-- documents dropping "the cached project index and resolution caches", and
-- the command should mean exactly what the docs say (principle of least
-- surprise, not correctness).
function M.clear_cache()
  if code_text_memo then
    code_text_memo:clear()
  end
end

-- Incremental byte-offset -> line-number resolver over `text`. Offsets must
-- be queried in nondecreasing order; producers like each_selective_use yield
-- statements in increasing offset order, so the line number can be tracked
-- incrementally -- a per-query prefix scan would be O(queries x textsize)
-- and hang on a file of use-lines. Returns the 1-based line number of byte
-- offset `off` and the offset of that line's first byte.
---@param text string
---@return fun(off: integer): integer, integer
function M.line_tracker(text)
  local cur_line, cur_off = 1, 1
  return function(off)
    while true do
      local nl = text:find("\n", cur_off, true)
      if not nl or nl >= off then
        return cur_line, cur_off
      end
      cur_line = cur_line + 1
      cur_off = nl + 1
    end
  end
end

---------------------------------------------------------------------------
-- Hardened file access
---------------------------------------------------------------------------

-- No real .masm file approaches this; a "file" beyond it is junk or a trap
-- (e.g. a `.masm`-named symlink pointing at something huge).
M.MAX_FILE_BYTES = 2 * 1024 * 1024

-- Freshness key for a file's content, used by every cache that must go stale
-- when the file changes. Includes the size so filesystems with coarse mtime
-- granularity still very likely produce a new key on save.
---@param path string
---@return string? key nil when the file cannot be stat'ed
---@return table? stat the uv.fs_stat result
function M.stat_key(path)
  local st = M.uv.fs_stat(path)
  if not st then
    return nil
  end
  return st.mtime.sec .. "." .. st.mtime.nsec .. "." .. st.size, st
end

-- Reads a file the index pointed at. The contents are untrusted (a cloned
-- repo can name anything `.masm`, including symlinks): only regular files are
-- read -- never FIFOs or devices, which can block forever or stream without
-- end -- and only up to MAX_FILE_BYTES.
---@param path string
---@return string? text nil for missing, non-regular or oversized files
function M.read_file(path)
  local _, st = M.stat_key(path)
  if not st or st.type ~= "file" or st.size > M.MAX_FILE_BYTES then
    return nil
  end
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  -- Bounded read, not "*a": closes the stat-then-read race, so a file
  -- swapped in between can still not deliver more than the cap.
  local text = f:read(M.MAX_FILE_BYTES + 1)
  f:close()
  if not text or #text > M.MAX_FILE_BYTES then
    return nil
  end
  return text
end

---@param path string
---@return boolean
function M.file_exists(path)
  local st = M.uv.fs_stat(path)
  return (st and st.type == "file") == true
end

-- The loaded buffer whose name is exactly `path`, if any. Deliberately not
-- `vim.fn.bufnr(path)`: that treats the argument as a file-name PATTERN, so
-- a path containing `[`, `*` or `,` can match (or fail to match) the wrong
-- buffer -- and rename's live-buffer-wins guarantee rides on this lookup.
---@param path string
---@return integer? bufnr
function M.loaded_bufnr(path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == path then
      return b
    end
  end
end

---------------------------------------------------------------------------
-- Buffer-argument normalization
---------------------------------------------------------------------------

-- The nil/0 = "current buffer" convention, normalized once at every public
-- entry point. Centralized so the narrowing is real for the type checker
-- too: the inline `(bufnr == nil or bufnr == 0) and current or bufnr`
-- expression left the value `integer?` for flow analysis, and every
-- downstream API call flagged it.
---@param bufnr integer? nil/0 = current buffer
---@return integer bufnr
function M.norm_bufnr(bufnr)
  if bufnr == nil or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

---------------------------------------------------------------------------
-- Bounded caches
---------------------------------------------------------------------------

---@class masm.util.Cache
---@field data table<string, any> the entries; iterate this directly when needed
---@field n integer current entry count
---@field cap integer maximum entry count before a full clear
local Cache = {}
Cache.__index = Cache

---@param key string
---@return any value `nil` when absent (`false` sentinels are preserved)
function Cache:get(key)
  return self.data[key]
end

-- Insert/replace/delete (`value == nil` deletes). When a NEW entry would
-- exceed the cap, the whole cache is cleared first. Full-clear-on-overflow
-- instead of an LRU on purpose: every entry here is cheap to recompute (the
-- sources are freshness-keyed re-reads), the caps are generous enough that
-- real projects never hit them, and a wipe is O(1) and predictable where
-- LRU bookkeeping would tax every hit -- an LRU is overkill.
---@param key string
---@param value any
function Cache:put(key, value)
  local had = self.data[key] ~= nil
  if value == nil then
    if had then
      self.n = self.n - 1
    end
    self.data[key] = nil
    return
  end
  if not had then
    if self.n >= self.cap then
      self.data, self.n = {}, 0
    end
    self.n = self.n + 1
  end
  self.data[key] = value
end

function Cache:clear()
  self.data, self.n = {}, 0
end

-- A bounded key -> value cache with full-clear-on-overflow (see Cache:put).
---@param cap integer
---@return masm.util.Cache
function M.new_cache(cap)
  return setmetatable({ data = {}, n = 0, cap = cap }, Cache)
end

return M
