-- Project index for Miden Assembly: miden-project.toml discovery, the
-- namespace -> file mapping and the per-index lookup caches. Split out of
-- masm.goto, which remains the public facade -- everything here is internal
-- plumbing shared by masm.resolve and masm.goto.
--
-- Name resolution model (mirrors the Miden assembler):
--   * A library root is a directory holding `miden-project.toml` whose `[lib]`
--     table gives `namespace` (e.g. "miden::standards") and optionally `path`
--     to the root module file. Submodule `a::b` of the library lives at
--     `<root_dir>/a/b.masm` (or `.../b/mod.masm`).
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

local M = {}

local uv = util.uv

---@class masm.Lib a library declared by a miden-project.toml manifest
---@field ns string[]? namespace segments (nil for a namespace-less kernel)
---@field kernel boolean `[lib] kind = "kernel"`
---@field root_file string the library's root module file
---@field root_dir string directory of the root module file

---@class masm.ProjectIndex
---@field libs masm.Lib[]
---@field masm string[] every indexed .masm file path
---@field masm_set table<string, true> the same paths as a set
---@field roots string[] the deduplicated scan roots
---@field mod_cache masm.util.Cache module path -> file (false = not found)
---@field sym_cache masm.util.Cache (file, name) -> resolution (see masm.resolve)
---@field file_cache masm.util.Cache file -> parsed interface (see masm.resolve)

local defaults = {
  extra_roots = {},
  ignore_dirs = { "target", "node_modules" },
}

-- User lists replace the defaults outright (tbl_deep_extend would merge
-- list-likes positionally, making the default ignore_dirs impossible to
-- shrink). A bare string is accepted as a one-element list. Anything else
-- falls back to the default LOUDLY (one-time notification): a mistyped
-- extra_roots silently narrowing resolution is exactly the kind of quiet
-- degradation the dialect-drift canary exists to prevent elsewhere.
local function get_config()
  local user = vim.g.masm_goto
  if user ~= nil and type(user) ~= "table" then
    vim.notify_once(
      ("masm goto: vim.g.masm_goto must be a table, got %s; using defaults"):format(type(user)),
      vim.log.levels.WARN
    )
    user = nil
  end
  user = user or {}
  local function as_list(v, field, fallback)
    if type(v) == "string" then
      return { v }
    end
    local ok = type(v) == "table"
    if ok then
      for _, item in ipairs(v) do
        if type(item) ~= "string" then
          ok = false
          break
        end
      end
    end
    if ok then
      return v
    end
    if v ~= nil then
      vim.notify_once(
        ("masm goto: vim.g.masm_goto.%s must be a string or a list of strings, got %s; using the default"):format(
          field,
          vim.inspect(v)
        ),
        vim.log.levels.WARN
      )
    end
    return fallback
  end
  return {
    extra_roots = as_list(user.extra_roots, "extra_roots", defaults.extra_roots),
    ignore_dirs = as_list(user.ignore_dirs, "ignore_dirs", defaults.ignore_dirs),
  }
end

-- Root-set key -> masm.ProjectIndex. A session only ever touches a handful
-- of root sets; the cap is pure overflow armor (each entry is a whole
-- project index, so the cap is small but still far beyond real use).
local cache = util.new_cache(64)

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

-- Test hook: the entry cap is otherwise an unreachable local, and generating
-- 200k real files to trip it is not acceptable in a test run.
-- tests/hardening_test.lua lowers it to exercise the truncation path; nil
-- (always, outside tests) means MAX_SCAN_ENTRIES.
M._max_scan_entries = nil

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
    if out.scanned >= (M._max_scan_entries or MAX_SCAN_ENTRIES) then
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
      -- must never be followed (util.read_file re-checks with fs_stat anyway).
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
  local text = util.read_file(toml_path)
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

-- The `[lib]` table may omit `path`; fall back to the conventional root file
-- names (account components are single files named after their directory).
-- `lib.path` comes from an untrusted manifest: it must stay under the
-- manifest's directory, or `use some::lib::x` would read files anywhere on
-- the machine (`path = "../../../../etc/passwd"`).
local function lib_root_file(toml_path, lib)
  local dir = vim.fs.dirname(toml_path)
  local rel = lib.path
  if rel and (rel:sub(1, 1) == "/" or rel:match("^%a:")) then
    return nil -- absolute path: refuse the whole library
  end
  if rel then
    -- Component-wise, not `rel:match("%.%.")`: a directory legitimately
    -- named `foo..bar` must not condemn the library; only a real `..`
    -- component traverses.
    for comp in rel:gmatch("[^/\\]+") do
      if comp == ".." then
        return nil
      end
    end
  end
  local candidates = rel and { dir .. "/" .. rel }
    or {
      dir .. "/mod.masm",
      dir .. "/lib.masm",
      dir .. "/" .. vim.fs.basename(dir) .. ".masm",
    }
  for _, c in ipairs(candidates) do
    if util.file_exists(c) then
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

-- Generous caps for the per-index lookup caches: far beyond what a real
-- project generates (see util.new_cache for the overflow policy).
local FILE_CACHE_CAP = 20000
local MOD_CACHE_CAP = 20000
local SYM_CACHE_CAP = 50000

-- Builds (or returns the cached) project index for the buffer at `bufpath`.
-- Configuration is read from vim.g.masm_goto on every build.
---@param bufpath string
---@return masm.ProjectIndex
function M.build_index(bufpath)
  local cfg = get_config()
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
  local cached = cache:get(key)
  if cached then
    return cached
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
  -- everything at once. `roots` and `masm_set` exist for file_written():
  -- deciding whether a just-saved file is covered-but-unindexed must not
  -- rescan anything.
  local index = {
    libs = {},
    masm = out.masm,
    mod_cache = util.new_cache(MOD_CACHE_CAP),
    sym_cache = util.new_cache(SYM_CACHE_CAP),
    file_cache = util.new_cache(FILE_CACHE_CAP),
  }
  index.roots = roots
  index.masm_set = {}
  for _, f in ipairs(out.masm) do
    index.masm_set[f] = true
  end
  for _, toml in ipairs(out.tomls) do
    local lib = parse_lib_table(toml)
    local root_file = lib_root_file(toml, lib)
    if root_file and (lib.namespace or lib.kind == "kernel") then
      table.insert(index.libs, {
        ns = lib.namespace and util.split_path(lib.namespace) or nil,
        kernel = lib.kind == "kernel",
        root_file = root_file,
        root_dir = vim.fs.dirname(root_file),
      })
    end
  end
  cache:put(key, index)
  return index
end

function M.clear_cache()
  cache:clear()
end

-- Called from a BufWritePost autocmd (plugin/miden-masm.lua, via
-- masm.goto._file_written) with the path of every saved `.masm` file or
-- `miden-project.toml`. The project index caches the file SET, and without
-- this hook a newly created file stayed invisible ("gd fails until you
-- somehow know to run :MasmRebuildIndex"). An index is dropped when the
-- saved file falls under one of its roots and it either is a manifest
-- (which can redefine a library) or is a .masm file the index has not seen.
-- Deletions and out-of-editor changes (e.g. git pull) still need
-- :MasmRebuildIndex.
---@param path string
function M.file_written(path)
  if path == "" then
    return
  end
  path = vim.fs.normalize(path)
  local manifest = vim.fs.basename(path) == "miden-project.toml"
  for key, index in pairs(cache.data) do
    for _, root in ipairs(index.roots) do
      if path == root or path:sub(1, #root + 1) == root .. "/" then
        if manifest or not index.masm_set[path] then
          cache:put(key, nil)
        end
        break
      end
    end
  end
end

-- Maps a full module path (list of segments) to its .masm file.
local function resolve_module_uncached(segs, index)
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
      if util.file_exists(c) then
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

-- Cache-backed module resolution (negative results cached as `false`).
---@param segs string[] module path segments
---@param index masm.ProjectIndex
---@return string? file the module's .masm file, nil when not found
function M.resolve_module(segs, index)
  local key = table.concat(segs, "::")
  local hit = index.mod_cache:get(key)
  if hit ~= nil then
    return hit or nil
  end
  local f = resolve_module_uncached(segs, index)
  index.mod_cache:put(key, f or false)
  return f
end

return M
