-- Reproducible benchmark for the README's performance paragraph. Run with:
--   nvim --headless --clean -l scripts/bench.lua <project-root>
-- where <project-root> is a real Miden workspace (e.g. a checkout of the
-- Miden protocol monorepo). Measures, through the plugin's public API:
--   * a cold references scan (index build included, references({sync=true})),
--   * a warm references scan (index and file caches populated),
--   * goto-style resolution (goto.resolve()) after warm-up, and
--   * stack analysis of the largest indexed file, cold and warm.
-- It then FAILS (nonzero exit) if a warm file-interface cache hit slows
-- more than 3x with ~200 unrelated buffers open -- the buffer-count-scaling
-- regression class (see the hot-path guard at the bottom).
-- Dependency-free on purpose; the quickfix window references() opens is
-- harmless headless.

local script = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(script, ":p")))
vim.opt.rtp:prepend(plugin_root)

local goto_mod = require("masm.goto")
local project = require("masm.project")
local stack = require("masm.stack")

local uv = vim.uv or vim.loop

local root = arg and arg[1]
if not root then
  io.stderr:write("usage: nvim --headless --clean -l scripts/bench.lua <project-root>\n")
  os.exit(2)
end
root = vim.fn.fnamemodify(root, ":p"):gsub("/$", "")
if vim.fn.isdirectory(root) ~= 1 then
  io.stderr:write("bench: not a directory: " .. root .. "\n")
  os.exit(2)
end

local function hrtime_ms(fn)
  local t0 = uv.hrtime()
  local res = fn()
  return (uv.hrtime() - t0) / 1e6, res
end

local function read_lines(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return vim.split(text, "\n", { plain = true })
end

-- Seed the index with any .masm file under the root; build_index then walks
-- from the project's own root (git root / outermost miden-project.toml).
local seed = vim.fs.find(function(name)
  return name:sub(-5) == ".masm"
end, { path = root, type = "file", limit = 1 })[1]
if not seed then
  io.stderr:write("bench: no .masm files under " .. root .. "\n")
  os.exit(2)
end

local index = project.build_index(seed)
local files = vim.deepcopy(index.masm)
table.sort(files)

-- Corpus stats and the largest file (stack-analysis target).
local total_lines, largest, largest_lines = 0, nil, 0
for _, f in ipairs(files) do
  local lines = read_lines(f)
  if lines then
    total_lines = total_lines + #lines
    if #lines > largest_lines then
      largest, largest_lines = f, #lines
    end
  end
end
if not largest then
  io.stderr:write("bench: no readable .masm files under " .. root .. "\n")
  os.exit(2)
end

-- Pick a deterministic references/resolve target: the first qualified
-- `exec.mod::proc` (in sorted file order) that actually resolves. The probe
-- warms caches, so everything is cleared again before the cold measurement.
local target_file, target_pos
for _, f in ipairs(files) do
  local lines = read_lines(f) or {}
  for lnum, line in ipairs(lines) do
    local s, _, segment = line:find("exec%.[%w_$]+::([%w_$]+)")
    if s then
      vim.cmd("edit! " .. vim.fn.fnameescape(f))
      local col = line:find(segment, s, true) - 1
      vim.api.nvim_win_set_cursor(0, { lnum, col })
      if goto_mod.resolve() then
        target_file, target_pos = f, { lnum, col }
      end
      break
    end
  end
  if target_file then
    break
  end
end
if not target_file then
  io.stderr:write("bench: no resolvable exec.mod::proc target found\n")
  os.exit(2)
end

local function place_target()
  vim.cmd("edit! " .. vim.fn.fnameescape(target_file))
  vim.api.nvim_win_set_cursor(0, target_pos)
end

-- Cold: every cache dropped, so this pays the index walk plus the scan.
goto_mod.clear_cache()
stack.clear_cache()
place_target()
local cold_ms, cold_refs = hrtime_ms(function()
  return goto_mod.references({ sync = true }) or {}
end)

-- Warm: median of three runs against populated caches.
local warm_runs = {}
for _ = 1, 3 do
  place_target()
  warm_runs[#warm_runs + 1] = hrtime_ms(function()
    return goto_mod.references({ sync = true })
  end)
end
table.sort(warm_runs)
local warm_ms = warm_runs[2]

-- Resolution: mean over 100 warmed-up calls (a single call is ~sub-ms).
place_target()
goto_mod.resolve()
local resolve_total = hrtime_ms(function()
  for _ = 1, 100 do
    goto_mod.resolve()
  end
end)
local resolve_ms = resolve_total / 100

-- Stack analysis of the largest file: cold drops only the analyzer's own
-- memos (the index stays, as it would mid-session); warm replays them.
local stack_lines = read_lines(largest) or {}
stack.clear_cache()
local stack_cold_ms = hrtime_ms(function()
  return stack.analyze_lines(stack_lines, largest)
end)
local stack_warm_ms = hrtime_ms(function()
  return stack.analyze_lines(stack_lines, largest)
end)

local rel_largest = largest:sub(#root + 2)
print(("miden-masm.nvim bench: %s"):format(root))
print(
  ("corpus: %d files, %d lines (largest: %s, %d lines)"):format(
    #files,
    total_lines,
    rel_largest,
    largest_lines
  )
)
print(
  ("references target: %s:%d (%d references)"):format(
    target_file:sub(#root + 2),
    target_pos[1],
    #cold_refs
  )
)
print(("  %-38s %8.1f ms"):format("references, cold (index + scan)", cold_ms))
print(("  %-38s %8.1f ms"):format("references, warm (median of 3)", warm_ms))
print(("  %-38s %8.2f ms"):format("resolve, warm (mean of 100)", resolve_ms))
print(("  %-38s %8.1f ms"):format("stack analysis, cold", stack_cold_ms))
print(("  %-38s %8.1f ms"):format("stack analysis, warm", stack_warm_ms))

-- Hot-path guard: a file-interface cache hit must not scale with the
-- session's buffer count. Every hit in masm.resolve.file_interface
-- revalidates its entry against the buffer list, and a regression there
-- (re-introducing the full Lua buffer walk per hit) is invisible to the
-- fixture tests -- they run with a handful of buffers -- but costs real
-- sessions dearly: measured 8.1x per hit at ~200 open buffers before the
-- remembered-bufnr revalidation. The probe is a file the index knows but
-- no buffer holds -- the common case during resolution (dep files are
-- rarely open), and the one whose old cost was the full walk. A full
-- resolve() would dilute the walk below detectability, hence the direct
-- module call. Runs last so the scratch buffers cannot pollute the
-- measurements above; median of three mean-of-2000 batches per side keeps
-- timer noise out of the verdict.
local resolve_mod = require("masm.resolve")
local probe
for _, f in ipairs(files) do
  if vim.fn.bufexists(f) == 0 then
    probe = f
    break
  end
end
if not probe then
  io.stderr:write("bench: no unopened .masm file to probe the hot path with\n")
  os.exit(2)
end
local function hit_batch_us()
  local runs = {}
  for _ = 1, 3 do
    runs[#runs + 1] = hrtime_ms(function()
      for _ = 1, 2000 do
        resolve_mod.file_interface(probe, index)
      end
    end)
  end
  table.sort(runs)
  return runs[2] / 2000 * 1000
end

resolve_mod.file_interface(probe, index) -- warm the entry; hits from here on
local few_buf_us = hit_batch_us()
for _ = 1, 200 do
  vim.api.nvim_create_buf(true, true)
end
local many_buf_us = hit_batch_us()
local ratio = many_buf_us / few_buf_us
print(
  ("  %-38s %8.2f us (%.2fx of %.2f us)"):format(
    "file-interface hit, ~200 buffers open",
    many_buf_us,
    ratio,
    few_buf_us
  )
)
-- 3x is deliberately generous. A healthy hit's only buffer-count-dependent
-- work is one bufexists() -- a C-speed exact-name lookup -- so it measures
-- ~1.3x at this buffer count, and headless timer noise stays within tens
-- of percent of that; the regression signature (per-hit Lua walk, two API
-- calls per buffer) measured ~8x. Any threshold well above the noise band
-- and well below the signature works; 3x can only trip on the real thing.
if ratio > 3.0 then
  io.stderr:write(
    ("bench: FAIL: file-interface hit slowed %.2fx with ~200 buffers open (limit 3x)\n"):format(
      ratio
    )
  )
  os.exit(1)
end
os.exit(0)
