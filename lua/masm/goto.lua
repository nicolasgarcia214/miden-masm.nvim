-- Go-to-definition for Miden Assembly (.masm).
--
-- Wired up as a buffer-local 'tagfunc' from `after/ftplugin/masm.lua`, so
-- `<C-]>`, `gd`, `:tag` and the tag stack (`<C-t>`) all work in .masm buffers.
--
-- Resolution is text-based, not tree-sitter-based, on purpose: the pinned
-- tree-sitter-masm grammar predates the current dialect and parses `use {..}
-- from ..`, `pub mod` and `use .. as ..` as ERROR nodes, which are exactly the
-- statements this module must understand.
--
-- Name resolution model (mirrors the Miden assembler):
--   * A library root is a directory holding `miden-project.toml` whose `[lib]`
--     table gives `namespace` (e.g. "miden::standards") and optionally `path`
--     to the root module file. Submodule `a::b` of the library lives at
--     `<root_dir>/a/b.masm` (or `.../b/mod.masm`).
--   * `use miden::foo::bar` imports module `bar`; `use .. as x` renames it;
--     `use {sym, orig as alias} from <module>` imports symbols directly.
--   * `exec.`/`call.`/`procref.` targets are `proc` names, local, imported or
--     qualified; `syscall.` targets live in the kernel library
--     (`[lib] kind = "kernel"`). `const` and `type` names resolve the same way.
--
-- Configuration (optional):
--   vim.g.masm_goto = {
--     -- Extra directories to scan for miden-project.toml libraries, e.g. a
--     -- miden-vm checkout so `std::..` / `miden::core::..` resolve.
--     extra_roots = { "~/work/miden-vm" },
--     -- Directory names never descended into while indexing.
--     ignore_dirs = { "target", "node_modules" },
--   }

local M = {}

local uv = vim.uv or vim.loop

local defaults = {
  extra_roots = {},
  ignore_dirs = { "target", "node_modules" },
}

-- User lists replace the defaults outright (tbl_deep_extend would merge
-- list-likes positionally, making the default ignore_dirs impossible to
-- shrink). A bare string is accepted as a one-element list.
local function get_config()
  local user = type(vim.g.masm_goto) == "table" and vim.g.masm_goto or {}
  local function as_list(v, fallback)
    if type(v) == "table" then
      return v
    elseif type(v) == "string" then
      return { v }
    end
    return fallback
  end
  return {
    extra_roots = as_list(user.extra_roots, defaults.extra_roots),
    ignore_dirs = as_list(user.ignore_dirs, defaults.ignore_dirs),
  }
end

local function split_path(path)
  local segs = {}
  for seg in path:gmatch("[^:]+") do
    table.insert(segs, seg)
  end
  return segs
end

-- Strips leading whitespace and a `pub ` modifier, so definition patterns can
-- anchor on the keyword.
local function strip_pub(line)
  return (line:gsub("^%s*", ""):gsub("^pub%s+", ""))
end

-- Reduces a line to scannable code, preserving its length and therefore every
-- token position: string-literal contents are blanked (a constant name inside
-- an error message is not a reference, and `use` statements inside strings or
-- comments must not register as imports) and `# ..` comments are blanked,
-- honoring `#` and `\"` escapes inside strings.
local function code_only(line)
  local out, in_str, esc, in_comment = {}, false, false, false
  for i = 1, #line do
    local c = line:sub(i, i)
    if in_comment then
      out[#out + 1] = " "
    elseif in_str then
      out[#out + 1] = " "
      if esc then
        esc = false
      elseif c == "\\" then
        esc = true
      elseif c == '"' then
        in_str = false
      end
    elseif c == '"' then
      in_str = true
      out[#out + 1] = " "
    elseif c == "#" then
      in_comment = true
      out[#out + 1] = " "
    else
      out[#out + 1] = c
    end
  end
  return table.concat(out)
end

-- Whole-text variant of code_only, applied line-wise so line numbers and
-- per-line offsets are preserved.
local function code_text(text)
  local out = {}
  for line in text:gmatch("([^\n]*)\n?") do
    out[#out + 1] = code_only(line)
  end
  return table.concat(out, "\n")
end

-- No real .masm file approaches this; a "file" beyond it is junk or a trap
-- (e.g. a `.masm`-named symlink pointing at something huge).
local MAX_FILE_BYTES = 2 * 1024 * 1024

-- Freshness key for a file's content, used by every cache that must go stale
-- when the file changes. Includes the size so filesystems with coarse mtime
-- granularity still very likely produce a new key on save.
local function stat_key(path)
  local st = uv.fs_stat(path)
  if not st then
    return nil
  end
  return st.mtime.sec .. "." .. st.mtime.nsec .. "." .. st.size, st
end

-- Reads a file the index pointed at. The contents are untrusted (a cloned
-- repo can name anything `.masm`, including symlinks): only regular files are
-- read -- never FIFOs or devices, which can block forever or stream without
-- end -- and only up to MAX_FILE_BYTES.
local function read_file(path)
  local _, st = stat_key(path)
  if not st or st.type ~= "file" or st.size > MAX_FILE_BYTES then
    return nil
  end
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  -- Bounded read, not "*a": closes the stat-then-read race, so a file
  -- swapped in between can still not deliver more than the cap.
  local text = f:read(MAX_FILE_BYTES + 1)
  f:close()
  if not text or #text > MAX_FILE_BYTES then
    return nil
  end
  return text
end

---------------------------------------------------------------------------
-- Project index: miden-project.toml discovery and namespace -> file mapping
---------------------------------------------------------------------------

local cache = {} -- cache key -> index

local function is_ignored(name, cfg)
  if name:sub(1, 1) == "." then
    return true
  end
  return vim.list_contains(cfg.ignore_dirs, name)
end

-- Bounds for the synchronous index walk: it runs on the UI thread on the
-- first jump, so a runaway root (a git-tracked $HOME, a huge vendored tree)
-- must stop instead of hanging Neovim. The entry cap counts every directory
-- entry LOOKED AT, not just collected .masm files -- a huge tree with few
-- .masm files must still terminate. Truncation is reported, not silent.
local MAX_SCAN_DEPTH = 12
local MAX_SCAN_ENTRIES = 200000

local function walk(dir, cfg, out, depth)
  if depth > MAX_SCAN_DEPTH then
    out.truncated = true
    return
  end
  local it = uv.fs_scandir(dir)
  if not it then
    return
  end
  while true do
    local name, typ = uv.fs_scandir_next(it)
    if not name then
      break
    end
    out.scanned = out.scanned + 1
    if out.scanned >= MAX_SCAN_ENTRIES then
      out.truncated = true
      return
    end
    local path = dir .. "/" .. name
    if typ == "directory" then
      -- Symlinked directories are deliberately not descended: that is what
      -- protects the walk from symlink loops (and from wandering outside the
      -- project). A symlinked vendored library therefore does not resolve.
      if not is_ignored(name, cfg) then
        walk(path, cfg, out, depth + 1)
      end
    elseif typ == "file" or typ == nil then
      -- Regular files only: a `.masm`-named symlink or FIFO in a cloned repo
      -- must never be followed (read_file re-checks with fs_stat anyway).
      if name == "miden-project.toml" then
        table.insert(out.tomls, path)
      elseif name:sub(-5) == ".masm" then
        table.insert(out.masm, path)
      end
    end
  end
end

-- Minimal TOML scan: only string keys of the `[lib]` table are needed.
local function parse_lib_table(toml_path)
  local lib, section = {}, nil
  local text = read_file(toml_path)
  if not text then
    return lib
  end
  for line in text:gmatch("([^\n]*)\n?") do
    local s = line:match("^%s*%[([^%]]+)%]")
    if s then
      section = s
    elseif section == "lib" then
      local k, v = line:match('^%s*([%w_-]+)%s*=%s*"([^"]*)"')
      if k then
        lib[k] = v
      end
    end
  end
  return lib
end

local function file_exists(path)
  local st = uv.fs_stat(path)
  return st and st.type == "file"
end

-- The `[lib]` table may omit `path`; fall back to the conventional root file
-- names (account components are single files named after their directory).
-- `lib.path` comes from an untrusted manifest: it must stay under the
-- manifest's directory, or `use some::lib::x` would read files anywhere on
-- the machine (`path = "../../../../etc/passwd"`).
local function lib_root_file(toml_path, lib)
  local dir = vim.fs.dirname(toml_path)
  local rel = lib.path
  if rel and (rel:sub(1, 1) == "/" or rel:match("%.%.") or rel:match("^%a:")) then
    return nil -- absolute or traversing path: refuse the whole library
  end
  local candidates = rel and { dir .. "/" .. rel }
    or {
      dir .. "/mod.masm",
      dir .. "/lib.masm",
      dir .. "/" .. vim.fs.basename(dir) .. ".masm",
    }
  for _, c in ipairs(candidates) do
    if file_exists(c) then
      -- The textual check above can be bypassed by a symlinked component
      -- inside a declared multi-segment path; compare resolved paths so the
      -- root file truly lives under the manifest's directory.
      local real_c, real_dir = uv.fs_realpath(c), uv.fs_realpath(dir)
      if real_c and real_dir and real_c:sub(1, #real_dir + 1) == real_dir .. "/" then
        return c
      end
      return nil
    end
  end
end

-- Highest directory worth indexing for this buffer: the git root if there is
-- one (libraries depend on sibling crates), otherwise the outermost directory
-- that still contains a miden-project.toml.
local function top_dir(path)
  local git = vim.fs.root(path, ".git")
  if git then
    return git
  end
  local last
  for dir in vim.fs.parents(path) do
    if uv.fs_stat(dir .. "/miden-project.toml") then
      last = dir
    end
  end
  return last or vim.fs.dirname(path)
end

local function build_index(bufpath, cfg)
  -- Deduplicate and drop roots nested under another root, so an extra_roots
  -- entry inside the project does not index (and later scan) files twice.
  local candidates = { top_dir(bufpath) }
  for _, r in ipairs(cfg.extra_roots) do
    table.insert(candidates, vim.fs.normalize(r))
  end
  table.sort(candidates, function(a, b)
    return #a < #b
  end)
  local roots = {}
  for _, r in ipairs(candidates) do
    local nested = false
    for _, kept in ipairs(roots) do
      if r == kept or r:sub(1, #kept + 1) == kept .. "/" then
        nested = true
        break
      end
    end
    if not nested then
      table.insert(roots, r)
    end
  end
  local key = table.concat(roots, "\n")
  if cache[key] then
    return cache[key]
  end

  local out = { tomls = {}, masm = {}, scanned = 0 }
  for _, root in ipairs(roots) do
    walk(root, cfg, out, 0)
  end
  if out.truncated then
    vim.notify(
      "masm goto: index truncated (depth > "
        .. MAX_SCAN_DEPTH
        .. " or > "
        .. MAX_SCAN_ENTRIES
        .. " directory entries); results may be incomplete. Narrow the project root or ignore_dirs.",
      vim.log.levels.WARN
    )
  end

  -- mod_cache / sym_cache / file_cache memoize module, symbol and per-file
  -- definition lookups; they live on the index so clear_cache() invalidates
  -- everything at once.
  local index = { libs = {}, masm = out.masm, mod_cache = {}, sym_cache = {}, file_cache = {} }
  for _, toml in ipairs(out.tomls) do
    local lib = parse_lib_table(toml)
    local root_file = lib_root_file(toml, lib)
    if root_file and (lib.namespace or lib.kind == "kernel") then
      table.insert(index.libs, {
        ns = lib.namespace and split_path(lib.namespace) or nil,
        kernel = lib.kind == "kernel",
        root_file = root_file,
        root_dir = vim.fs.dirname(root_file),
      })
    end
  end
  cache[key] = index
  return index
end

function M.clear_cache()
  cache = {}
end

-- Maps a full module path (list of segments) to its .masm file.
local function resolve_module(segs, index)
  -- Malformed paths (e.g. a stray `use ::` in indexed text) split to zero
  -- segments; report "not found" instead of erroring downstream.
  if #segs == 0 then
    return nil
  end
  local best, best_len
  for _, lib in ipairs(index.libs) do
    if lib.ns and #lib.ns <= #segs and (not best_len or #lib.ns > best_len) then
      local match = true
      for i, s in ipairs(lib.ns) do
        if segs[i] ~= s then
          match = false
          break
        end
      end
      if match then
        best, best_len = lib, #lib.ns
      end
    end
  end
  if best then
    if best_len == #segs then
      return best.root_file
    end
    local rel = table.concat(segs, "/", best_len + 1)
    for _, c in ipairs({
      best.root_dir .. "/" .. rel .. ".masm",
      best.root_dir .. "/" .. rel .. "/mod.masm",
    }) do
      if file_exists(c) then
        return c
      end
    end
    -- A library claimed this namespace, so it is authoritative: a missing
    -- submodule file means "not found", never a guess elsewhere.
    return nil
  end
  -- No library claims this namespace (e.g. a dependency whose sources are not
  -- checked out): fall back to matching the FULL segment path against every
  -- indexed .masm file. Deliberately no bare-basename fallback: jumping to
  -- any same-named file anywhere would be a silent guess, and the documented
  -- contract is to report a reason instead.
  local suffixes = {
    "/" .. table.concat(segs, "/") .. ".masm",
    "/" .. table.concat(segs, "/") .. "/mod.masm",
  }
  for _, suffix in ipairs(suffixes) do
    -- Deterministic tie-break among ambiguous matches: shortest path, then
    -- lexicographic, rather than filesystem enumeration order.
    local best_f
    for _, f in ipairs(index.masm) do
      if
        f:sub(-#suffix) == suffix and (not best_f or #f < #best_f or (#f == #best_f and f < best_f))
      then
        best_f = f
      end
    end
    if best_f then
      return best_f
    end
  end
end

---------------------------------------------------------------------------
-- Import parsing (works on raw text so ERROR nodes in the grammar are moot)
---------------------------------------------------------------------------

-- Iterates the `sym` / `orig as alias` items of a `use {..} from <mod>` list.
-- Stops early (and returns true) when `fn` returns true.
local function each_use_item(braces, fn)
  for item in braces:gmatch("[^,]+") do
    local orig, alias = item:match("([%w_]+)%s+as%s+([%w_]+)")
    if not orig then
      orig = item:match("^%s*([%w_]+)%s*$")
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
local function each_selective_use(code, pub_only, fn)
  -- `%f[%w_]`, not `%f[%w]`: the keyword must not be the tail of a longer
  -- identifier like `my_use`.
  local pat = pub_only and "%f[%w_]pub%s+use%s*{()" or "%f[%w_]use%s*{()"
  local init = 1
  while true do
    local s, brace_open, bpos = code:find(pat, init)
    if not s then
      return
    end
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

-- Collects the import maps of a buffer's text:
--   mods:  local qualifier -> module path segments   (use a::b [as x])
--   syms:  local name -> { mod = segments, orig = original name }
local function parse_imports(text)
  local mods, syms = {}, {}
  -- Scan code only: a `use` statement quoted in a comment or an error string
  -- must not register an import.
  text = code_text(text)
  -- Selective imports may span lines: `use {\n  a,\n  b,\n} from path`.
  each_selective_use(text, false, function(stmt)
    local mod_segs = split_path(stmt.mod)
    each_use_item(stmt.braces, function(orig, alias)
      syms[alias] = { mod = mod_segs, orig = orig }
    end)
  end)
  for line in text:gmatch("[^\n]+") do
    local l = strip_pub(line)
    local mod, alias = l:match("^use%s+([%w_:]+)%s+as%s+([%w_]+)")
    if not mod then
      -- Legacy arrow-alias form from the pre-`as` dialect (the pinned
      -- tree-sitter grammar's import_alias rule still spells it this way).
      mod, alias = l:match("^use%s+([%w_:]+)%s*%-%>%s*([%w_]+)")
    end
    if not mod then
      mod = l:match("^use%s+([%w_:]+)%s*$")
      if mod then
        local segs = split_path(mod)
        alias = segs[#segs]
      end
    end
    if mod and alias then
      mods[alias] = split_path(mod)
    end
  end
  return mods, syms
end

---------------------------------------------------------------------------
-- Symbol lookup inside a module file
---------------------------------------------------------------------------

-- Finds the definition line of `name` (a proc, const or type) in `text`.
-- `name` is escaped: it may come from user-typed `:tag` input. The frontier
-- is `%f[^%w_]`, not `%f[%W]`: Lua's %w excludes `_`, so the latter would
-- let `add` match the definition of `add_checked`.
local function find_def_line(text, name)
  local pat = vim.pesc(name)
  local lnum = 0
  for line in text:gmatch("([^\n]*)\n?") do
    lnum = lnum + 1
    local l = strip_pub(line)
    for _, kw in ipairs({ "proc", "const", "type" }) do
      if l:match("^" .. kw .. "%s+" .. pat .. "%f[^%w_]") then
        return lnum
      end
    end
  end
end

local function resolve_module_cached(segs, index)
  local key = table.concat(segs, "::")
  local hit = index.mod_cache[key]
  if hit ~= nil then
    return hit or nil
  end
  local f = resolve_module(segs, index)
  index.mod_cache[key] = f or false
  return f
end

-- A file's parsed interface -- its definitions as a name -> line map plus
-- its `pub use` re-export statements -- built in ONE pass over the file and
-- cached under its freshness key. This is what keeps references() linear:
-- resolving N distinct names against the same module must not re-read and
-- re-scan that module N times (measured: ~10 ms per scan of a 130 KB file,
-- so a per-name re-scan turned 2000 names into ~20 s of frozen UI).
local function file_interface(path, index)
  local key = stat_key(path) or "?"
  local entry = index.file_cache[path]
  if entry and entry.key == key then
    return entry
  end
  entry = { key = key, defs = {}, reexports = {} }
  local text = read_file(path)
  if text then
    local lnum = 0
    for line in text:gmatch("([^\n]*)\n?") do
      lnum = lnum + 1
      local l = strip_pub(line)
      local kw, name = l:match("^(%a+)%s+([%w_]+)")
      if (kw == "proc" or kw == "const" or kw == "type") and not entry.defs[name] then
        entry.defs[name] = lnum
      end
    end
    -- Only `pub use` re-exports a name; private imports are not interface.
    each_selective_use(code_text(text), true, function(stmt)
      local items = {}
      each_use_item(stmt.braces, function(orig, alias)
        items[#items + 1] = { orig = orig, alias = alias }
      end)
      entry.reexports[#entry.reexports + 1] = { mod = stmt.mod, items = items }
    end)
  end
  index.file_cache[path] = entry
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
-- Negative results are cached only for complete (depth-0) searches, so a
-- search truncated by the depth cap cannot poison a later, shallower one.
local function find_symbol(path, name, index, depth, visited)
  if depth > MAX_REEXPORT_DEPTH then
    return nil
  end
  local key = path .. "\1" .. name
  visited = visited or {}
  if visited[key] and visited[key] <= depth then
    return nil
  end
  visited[key] = depth

  local iface = file_interface(path, index)
  -- Cache entries carry the searched file's freshness key: a string entry is
  -- a negative result (valid only while that file is unchanged, so "write
  -- the call site, gd fails, write the proc, gd works" behaves); a table
  -- entry is { def file, def name, freshness }, re-resolved when the
  -- searched file changes (a `pub use` line may have been retargeted).
  local src = iface.key
  local hit = index.sym_cache[key]
  if hit ~= nil then
    if type(hit) == "string" then
      if hit == src then
        return nil
      end
      index.sym_cache[key] = nil
    elseif hit[3] ~= src then
      index.sym_cache[key] = nil
    else
      local lnum = file_interface(hit[1], index).defs[hit[2]]
      if lnum then
        return hit[1], lnum, hit[2]
      end
      index.sym_cache[key] = nil -- definition moved away; re-resolve below
    end
  end

  local lnum = iface.defs[name]
  if lnum then
    index.sym_cache[key] = { path, name, src }
    return path, lnum, name
  end
  for _, re in ipairs(iface.reexports) do
    for _, it in ipairs(re.items) do
      if it.alias == name then
        local f = resolve_module_cached(split_path(re.mod), index)
        if f then
          local p, l, dn = find_symbol(f, it.orig, index, depth + 1, visited)
          if p then
            index.sym_cache[key] = { p, dn, src }
            return p, l, dn
          end
        end
      end
    end
  end
  if depth == 0 then
    index.sym_cache[key] = src
  end
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
    local ts, te = line:find("[%w_%$:]+", init)
    if not ts then
      return nil
    end
    if col < te then
      s, e, token = ts, te, line:sub(ts, te)
      break
    end
    init = te + 1
  end
  local kind
  if INVOKE_KINDS[token] and line:sub(e + 1, e + 1) == "." then
    -- Cursor on `exec` itself: the target is the token after the dot.
    kind = token
    s = e + 2
    token = line:match("^[%w_%$:]+", s)
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
  -- Which segment is the cursor on?
  local active, off = #segs, math.max(col + 1 - s, 0)
  local pos = 0
  for i, seg in ipairs(segs) do
    pos = pos + #seg
    if off < pos + 2 then -- +2 tolerates the cursor sitting on the `::`
      active = i
      break
    end
    pos = pos + 2
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
  each_selective_use(text, false, function(stmt)
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

-- `kind` ("symbol" or "module") rides along in the tag item's user_data
-- field so references() knows what was resolved without re-deriving it.
local function tag_item(name, path, lnum, kind)
  return { name = name, filename = path, cmd = tostring(lnum or 1), user_data = kind or "symbol" }
end

-- Expands a leading module alias: `asset_utils::x` -> `miden::protocol_utils::asset::x`.
local function expand_alias(segs, mods)
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
local function resolve_path(segs, active, kind, mods, syms, buftext, bufpath, index)
  -- Cursor on a qualifier segment: jump to that module's file.
  if active < #segs then
    local prefix = expand_alias(vim.list_slice(segs, 1, active), mods)
    local file = resolve_module_cached(prefix, index)
    if file then
      return tag_item(segs[active], file, 1, "module")
    end
    return nil, "module " .. table.concat(prefix, "::") .. " not found"
  end

  local name = segs[#segs]

  if #segs == 1 then
    -- `syscall.name` targets the kernel library.
    if kind == "syscall" then
      for _, lib in ipairs(index.libs) do
        if lib.kernel then
          local p, l = find_symbol(lib.root_file, name, index, 0)
          if p then
            return tag_item(name, p, l)
          end
        end
      end
      return nil, "kernel procedure " .. name .. " not found"
    end
    -- Definition in the current file.
    local lnum = find_def_line(buftext, name)
    if lnum then
      return tag_item(name, bufpath, lnum)
    end
    -- Symbol imported via `use {..} from ..`.
    local imp = syms[name]
    if imp then
      local file = resolve_module_cached(imp.mod, index)
      if not file then
        return nil, "module " .. table.concat(imp.mod, "::") .. " not found"
      end
      local p, l = find_symbol(file, imp.orig, index, 0)
      if p then
        return tag_item(name, p, l)
      end
      return nil, imp.orig .. " not found in " .. table.concat(imp.mod, "::")
    end
    -- A module qualifier on its own (e.g. the cursor on `x` of `use a::b as x`
    -- elsewhere in the file).
    if mods[name] then
      local file = resolve_module_cached(mods[name], index)
      if file then
        return tag_item(name, file, 1, "module")
      end
    end
    return nil, "no definition or import of " .. name .. " in this file"
  end

  -- Qualified: `qualifier::name` or a full `a::b::name` path.
  local mod_segs = expand_alias(vim.list_slice(segs, 1, #segs - 1), mods)
  local file = resolve_module_cached(mod_segs, index)
  if not file then
    return nil, "module " .. table.concat(mod_segs, "::") .. " not found"
  end
  local p, l = find_symbol(file, name, index, 0)
  if p then
    return tag_item(name, p, l)
  end
  return nil, name .. " not found in " .. table.concat(mod_segs, "::")
end

-- Context-sensitive resolution for the statement forms goto can start from.
local function resolve_at_cursor(index, buftext, bufpath)
  local t = cursor_target()
  if not t then
    return nil, "nothing under cursor"
  end
  local mods, syms = parse_imports(buftext)
  local stripped = strip_pub(t.line)

  -- `pub mod name` (mod.masm): open the submodule file next to this one.
  if stripped:match("^mod%s+" .. vim.pesc(t.token) .. "%f[^%w_]") then
    local dir = vim.fs.dirname(bufpath)
    for _, c in ipairs({ dir .. "/" .. t.token .. ".masm", dir .. "/" .. t.token .. "/mod.masm" }) do
      if file_exists(c) then
        return tag_item(t.token, c, 1, "module")
      end
    end
    return nil, "submodule file for " .. t.token .. " not found"
  end

  -- `use {..} from <mod>` statements, including multi-line ones.
  local stmt = use_statement_at_cursor()
  if stmt then
    local file = resolve_module_cached(split_path(stmt.mod), index)
    if not file then
      return nil, "module " .. stmt.mod .. " not found"
    end
    if stmt.in_braces then
      local orig = t.token
      each_use_item(stmt.braces, function(o, a)
        if a == t.token then
          orig = o
          return true
        end
      end)
      local p, l = find_symbol(file, orig, index, 0)
      if p then
        return tag_item(t.token, p, l)
      end
      return nil, orig .. " not found in " .. stmt.mod
    end
    -- Cursor on the module path: jump to the module named by the segment
    -- under the cursor (a prefix segment resolves to its own module file).
    if t.token:find(":") then
      local prefix = vim.list_slice(t.segs, 1, t.active)
      local f = resolve_module_cached(prefix, index)
      if f then
        return tag_item(t.segs[t.active], f, 1, "module")
      end
      return nil, "module " .. table.concat(prefix, "::") .. " not found"
    end
    return tag_item(vim.fs.basename(file), file, 1, "module")
  end

  -- Plain `use a::b` / `use a::b as x` lines: jump to the module file.
  if stripped:match("^use%f[^%w_]") then
    local prefix = vim.list_slice(t.segs, 1, t.active)
    if #prefix == 1 and mods[t.token] then
      prefix = mods[t.token] -- cursor on the alias name itself
    end
    local file = resolve_module_cached(prefix, index)
    if file then
      return tag_item(t.segs[t.active], file, 1, "module")
    end
    return nil, "module " .. table.concat(prefix, "::") .. " not found"
  end

  return resolve_path(t.segs, t.active, t.kind, mods, syms, buftext, bufpath, index)
end

---------------------------------------------------------------------------
-- References
---------------------------------------------------------------------------

-- Collects every usage in `text` (one file) that resolves to the definition
-- at (def_path, def_lnum) whose definition-site name is `def_name`. Renamed
-- re-exports are handled by resolving each candidate, not by name matching.
local function collect_symbol_refs(f, text, def_path, def_lnum, def_name, index, add)
  local mods, syms = parse_imports(text)
  -- Local names in this file that resolve to the definition.
  local local_names = {}
  if f == def_path then
    local_names[def_name] = true
  end
  for alias, imp in pairs(syms) do
    local mf = resolve_module_cached(imp.mod, index)
    if mf then
      local p, l = find_symbol(mf, imp.orig, index, 0)
      if p == def_path and l == def_lnum then
        local_names[alias] = true
      end
    end
  end

  local lnum = 0
  for raw in text:gmatch("([^\n]*)\n?") do
    lnum = lnum + 1
    local line = code_only(raw)
    for s, tok in line:gmatch("()([%w_%$:]+)") do
      if tok:find(":") then
        local segs = split_path(tok)
        if #segs >= 2 then
          local prefix = expand_alias(vim.list_slice(segs, 1, #segs - 1), mods)
          local mf = resolve_module_cached(prefix, index)
          if mf then
            local p, l = find_symbol(mf, segs[#segs], index, 0)
            if p == def_path and l == def_lnum then
              add(f, lnum, s, raw)
            end
          end
        end
      elseif local_names[tok] then
        add(f, lnum, s, raw)
      elseif line:sub(1, s - 1):match("([%w_]+)%.$") == "syscall" then
        -- `syscall.name` needs no import; resolve against the kernel library.
        for _, lib in ipairs(index.libs) do
          if lib.kernel then
            local p, l = find_symbol(lib.root_file, tok, index, 0)
            if p == def_path and l == def_lnum then
              add(f, lnum, s, raw)
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
  -- line number can be tracked incrementally -- a per-statement prefix scan
  -- would be O(statements x filesize) and hang on a file of use-lines.
  local cur_line, cur_off = 1, 1
  local function lnum_of(off)
    while true do
      local nl = code:find("\n", cur_off, true)
      if not nl or nl >= off then
        return cur_line
      end
      cur_line = cur_line + 1
      cur_off = nl + 1
    end
  end
  each_selective_use(code, false, function(stmt)
    if resolve_module_cached(split_path(stmt.mod), index) == def_path then
      raw_lines = raw_lines or vim.split(text, "\n")
      local l = lnum_of(stmt.start)
      add(f, l, 1, raw_lines[l] or "")
    end
  end)
  local lnum = 0
  for raw in text:gmatch("([^\n]*)\n?") do
    lnum = lnum + 1
    local l = strip_pub(code_only(raw))
    local mod = l:match("^use%s+([%w_:]+)%s+as%s+[%w_]+") or l:match("^use%s+([%w_:]+)%s*$")
    if mod and resolve_module_cached(split_path(mod), index) == def_path then
      add(f, lnum, 1, raw)
    end
  end
end

-- Finds all references to the symbol (or module) under the cursor across the
-- indexed project and populates the quickfix list. The definition comes first.
function M.references()
  local bufpath = vim.api.nvim_buf_get_name(0)
  if bufpath == "" then
    return
  end
  local cfg = get_config()
  local ok, index = pcall(build_index, bufpath, cfg)
  if not ok then
    vim.notify("masm references: indexing failed: " .. tostring(index), vim.log.levels.ERROR)
    return
  end
  local buftext = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")

  local res_ok, item, reason = pcall(resolve_at_cursor, index, buftext, bufpath)
  if not res_ok then
    vim.notify("masm references: " .. tostring(item), vim.log.levels.ERROR)
    return
  end
  if not item then
    vim.notify("masm references: " .. (reason or "cannot resolve"), vim.log.levels.WARN)
    return
  end
  local def_path, def_lnum = item.filename, tonumber(item.cmd)

  -- The resolver tags what it found (module file vs symbol) in user_data.
  -- For symbols, read the definition line for its keyword and definition-site
  -- name (which may differ from the cursor's name across renamed imports).
  local is_symbol = item.user_data ~= "module"
  local kw, def_name
  if is_symbol then
    -- def_lnum was resolved against the current buffer's (possibly unsaved)
    -- text when the definition lives here; the def line must come from the
    -- same source, or unsaved edits above it would silently make the scan
    -- describe whatever symbol sits on that disk line instead.
    local def_text = (def_path == bufpath and buftext) or read_file(def_path) or ""
    local def_line = vim.split(def_text, "\n")[def_lnum] or ""
    kw, def_name = strip_pub(def_line):match("^(%a+)%s+([%w_]+)")
    if not def_name then
      vim.notify(
        "masm references: no definition at " .. def_path .. ":" .. def_lnum,
        vim.log.levels.WARN
      )
      return
    end
  end

  local items, seen = {}, {}
  local function add(f, lnum, col, text)
    local key = f .. ":" .. lnum .. ":" .. col
    if not seen[key] then
      seen[key] = true
      table.insert(items, { filename = f, lnum = lnum, col = col, text = vim.trim(text) })
    end
  end

  -- One unreadable or pathological file must not kill the whole scan.
  local scan_errors = 0
  for _, f in ipairs(index.masm) do
    -- Unsaved edits in the current buffer take precedence over disk.
    local text = f == bufpath and buftext or read_file(f)
    if text then
      local ok
      if is_symbol then
        ok = pcall(collect_symbol_refs, f, text, def_path, def_lnum, def_name, index, add)
      else
        ok = pcall(collect_module_refs, f, text, def_path, index, add)
      end
      if not ok then
        scan_errors = scan_errors + 1
      end
    end
  end
  if scan_errors > 0 then
    vim.notify("masm references: failed to scan " .. scan_errors .. " file(s)", vim.log.levels.WARN)
  end

  table.sort(items, function(a, b)
    local a_def = a.filename == def_path and a.lnum == def_lnum
    local b_def = b.filename == def_path and b.lnum == def_lnum
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

  if #items == 0 then
    vim.notify("masm references: no references found", vim.log.levels.WARN)
    return
  end
  local what = is_symbol and (kw .. " " .. def_name) or ("module " .. vim.fs.basename(def_path))
  vim.fn.setqflist({}, " ", { title = "MASM references: " .. what, items = items })
  vim.cmd("botright copen")
  return items
end

---------------------------------------------------------------------------
-- Document symbols
---------------------------------------------------------------------------

-- Lists the current buffer's top-level definitions (procs, consts, types,
-- submodules, entrypoint) in the location list.
function M.document_symbols()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local bufnr = vim.api.nvim_get_current_buf()
  local items = {}
  for i, line in ipairs(lines) do
    local l = strip_pub(line)
    if
      l:match("^proc%s+[%w_]")
      or l:match("^const%s+[%w_]")
      or l:match("^type%s+[%w_]")
      or l:match("^mod%s+[%w_]")
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
function M.resolve()
  local bufpath = vim.api.nvim_buf_get_name(0)
  if bufpath == "" then
    return nil, "unnamed buffer"
  end
  local ok, index = pcall(build_index, bufpath, get_config())
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

-- Bounded, symlink/FIFO-safe file read, shared with masm.hover so hovers
-- honor the same untrusted-input rules as the index. Not public API.
M._read_file = read_file

-- Comment/string blanking and cache freshness keys, shared with masm.stack so
-- the analyzer scans code and invalidates caches by exactly the same rules as
-- the index. Not public API.
M._code_only = code_only
M._stat_key = stat_key

-- Builds a cursor-independent resolver over this buffer's imports and the
-- project index, for callers (masm.stack) that resolve many invocation
-- targets per pass: the index and import parse happen once here, each
-- returned call is then cache-backed. `kind` is the invocation keyword
-- ("exec"/"call"/"syscall"/"procref"); syscall targets resolve against the
-- kernel library exactly as cursor resolution would.
function M.make_resolver(bufpath, buftext)
  local ok, index = pcall(build_index, bufpath, get_config())
  if not ok then
    return nil, "indexing failed: " .. tostring(index)
  end
  local mods, syms = parse_imports(buftext)
  return function(target, kind)
    local token = target:match("^:*(.-):*$")
    if not token or token == "" then
      return nil, "empty target"
    end
    local segs = split_path(token)
    local res_ok, item, reason =
      pcall(resolve_path, segs, #segs, kind, mods, syms, buftext, bufpath, index)
    if not res_ok then
      return nil, tostring(item)
    end
    return item, reason
  end
end

-- 'tagfunc' implementation. With the 'c' flag (normal-mode <C-]> / gd) the
-- cursor context drives resolution; otherwise `pattern` (from `:tag foo` or
-- tag completion) is parsed as a plain path.
function M.tagfunc(pattern, flags, _)
  local bufpath = vim.api.nvim_buf_get_name(0)
  if bufpath == "" then
    return vim.NIL
  end
  local cfg = get_config()
  local ok, index = pcall(build_index, bufpath, cfg)
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
    if not pattern:match("^[%w_%$:]+$") then
      return {}
    end
    local segs = split_path(pattern)
    if #segs == 0 then
      return {}
    end
    local mods, syms = parse_imports(buftext)
    item, reason = resolve_path(segs, #segs, nil, mods, syms, buftext, bufpath, index)
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
