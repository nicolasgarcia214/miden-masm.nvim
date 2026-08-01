-- Shared per-suite plumbing for the test suites: the runtimepath preamble,
-- the check()/place() helpers and the exit epilogue, previously copy-pasted
-- into every suite. Loaded via dofile -- each suite derives this file's path
-- from its own script location, so `nvim --headless --clean -l
-- tests/x_test.lua` works from any cwd. Suites keep full process isolation:
-- every `make test` line is its own Neovim, and the only state here is that
-- process's own failure counter -- no fixture paths, buffers or caches are
-- shared through this module.

local M = {}

-- tests/ and the plugin root, derived from THIS file's location. Loading
-- the helpers is what puts the plugin on 'runtimepath'.
M.here = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
M.plugin_root = vim.fs.dirname(M.here)
vim.opt.rtp:prepend(M.plugin_root)

-- A fresh temp directory in its CANONICAL (symlink-resolved) spelling.
-- Neovim spells buffer names with symlinks resolved, and the temp base can
-- sit behind one (macOS's /var -> /private/var is the everyday case) -- a
-- suite comparing tempname-derived paths against buffer names or index
-- paths would then mismatch on the spelling alone. Resolving once here
-- keeps every path derived from the returned root comparable.
---@return string dir
function M.temp_dir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return (vim.uv or vim.loop).fs_realpath(d) or d
end

-- Failures so far. check() increments it; suites with bespoke assertion
-- loops (masm's go-to-def table, the queries suite) increment it directly.
M.failed = 0

-- One PASS/FAIL line per assertion; `detail` is printed on failure only.
---@param desc string
---@param ok any truthiness is the verdict
---@param detail string? shown after the description on failure
function M.check(desc, ok, detail)
  if ok then
    print("PASS: " .. desc)
  else
    print("FAIL: " .. desc .. (detail and (" -- " .. detail) or ""))
    M.failed = M.failed + 1
  end
end

-- place(file, find, off) bound to a fixture root: opens `root .. file` and
-- puts the cursor on the first occurrence of the plain-text `find`, plus
-- `off` bytes. A missing locator is an error -- a typo'd locator must fail
-- the suite loudly, never leave the cursor wherever the previous case put
-- it.
---@param root string fixture root the file paths are relative to
---@return fun(file: string, find: string, off: integer?): boolean
function M.placer(root)
  return function(file, find, off)
    vim.cmd("edit! " .. root .. file)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    for i, l in ipairs(lines) do
      local s = l:find(find, 1, true)
      if s then
        vim.api.nvim_win_set_cursor(0, { i, s - 1 + (off or 0) })
        return true
      end
    end
    error("locator not found: " .. find .. " in " .. file)
  end
end

-- Uniform suite epilogue: the "ALL PASS" sentinel (or the failure count)
-- and a nonzero exit so `make test` stops at the first failing suite.
function M.finish()
  print(M.failed == 0 and "ALL PASS" or (M.failed .. " FAILURES"))
  if M.failed > 0 then
    os.exit(1)
  end
end

return M
