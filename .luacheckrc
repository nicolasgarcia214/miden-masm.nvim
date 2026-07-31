-- Luacheck configuration for the plugin and its test suites.
-- Neovim embeds LuaJIT, so the LuaJIT standard library is the right baseline;
-- `vim` is the only global the runtime injects on top of it.
std = "luajit"
read_globals = { "vim" }

-- Neovim's variable/option scopes are the sanctioned mutation surface, so
-- writes through them are fine; everything else on `vim` stays read-only,
-- which keeps "vim.notify = ..." in plugin code a lint error.
globals = {
  "vim.g",
  "vim.b",
  "vim.w",
  "vim.t",
  "vim.v",
  "vim.o",
  "vim.go",
  "vim.bo",
  "vim.wo",
  "vim.opt",
  "vim.opt_local",
  "vim.opt_global",
  "vim.env",
}

-- Underscore-prefixed locals/arguments are the deliberate "intentionally
-- unused" convention here (e.g. a handler keeping the dispatch signature).
ignore = { "21/_.*" }

-- Line length is stylua's job, not the linter's.
max_line_length = false

-- scripts/ is linted too (bench.lua); the Python generator there never
-- reaches luacheck, which only collects .lua files from a directory.
exclude_files = {
  "tests/.parser-build",
}

-- Test harnesses stub vim.* functions (vim.notify, vim.ui.input, vim.health)
-- to observe plugin behavior headlessly, so the whole `vim` table is
-- writable there -- but only there.
files["tests"] = {
  globals = { "vim" },
}
