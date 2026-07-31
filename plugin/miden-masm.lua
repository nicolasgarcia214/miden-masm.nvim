-- Registers the Miden Assembly tree-sitter parser with nvim-treesitter
-- (main branch). Everything else in this plugin is driven per-buffer from
-- `after/ftplugin/masm.lua` and works without the parser; the parser only
-- powers highlighting, indentation, folds and textobjects.
--
-- `User TSUpdate` is nvim-treesitter's documented extension point for custom
-- parsers. It matters that this is an autocmd rather than a one-off
-- assignment: `install`/`update` deliberately drop
-- `package.loaded['nvim-treesitter.parsers']`, re-require it and then fire
-- `User TSUpdate`, precisely so that user-registered parsers get re-applied
-- to the freshly built table. Assigning once at startup would be silently
-- discarded by that reload, and `:TSInstall masm` would report
-- "unsupported language".
-- Version guard first: on an older Neovim the plugin would load fine and
-- then die much later with an obscure error deep in some API call. Failing
-- loudly here names the actual problem once.
if vim.fn.has("nvim-0.10.4") ~= 1 then
  vim.notify_once(
    "miden-masm.nvim requires Neovim >= 0.10.4; the plugin is disabled",
    vim.log.levels.ERROR
  )
  return
end

if vim.g.loaded_miden_masm then
  return
end
vim.g.loaded_miden_masm = 1

-- Neovim's built-in `*.masm` -> masm detection only exists on 0.11+; on the
-- advertised 0.10.4 floor the extension is unknown and buffers fall back to
-- `conf`, so nothing in this plugin would activate. Registering it here is a
-- no-op on 0.11+ (same extension, same filetype).
vim.filetype.add({ extension = { masm = "masm" } })

-- Keep the goto project index honest about the file SET: it caches which
-- .masm files and manifests exist, and a file created after the first jump
-- would otherwise stay invisible until :MasmRebuildIndex. Saving a .masm
-- file the index has not seen (or any manifest) drops the affected index;
-- masm.goto is only consulted when already loaded -- this must not pull the
-- whole resolver in just because some .masm file got written.
vim.api.nvim_create_autocmd("BufWritePost", {
  pattern = { "*.masm", "miden-project.toml" },
  group = vim.api.nvim_create_augroup("miden_masm_index", { clear = true }),
  callback = function(ev)
    local goto_mod = package.loaded["masm.goto"]
    if goto_mod then
      goto_mod._file_written(vim.api.nvim_buf_get_name(ev.buf))
    end
  end,
})

vim.api.nvim_create_autocmd("User", {
  pattern = "TSUpdate",
  group = vim.api.nvim_create_augroup("miden_masm_parser", { clear = true }),
  callback = function()
    require("nvim-treesitter.parsers").masm = {
      install_info = {
        url = "https://github.com/0xMiden/tree-sitter-masm",
        -- Pinned: the repo publishes no tags, and the queries in
        -- `queries/masm/` were ported against this exact revision.
        revision = "3dfc7c1f687a0a287afe3b1c01ff7be6f0a42241",
      },
      -- nvim-treesitter's tiers are 1 stable / 2 unstable / 3 unmaintained /
      -- 4 unsupported; "unstable" fits a young grammar that trails its dialect.
      tier = 2,
    }
  end,
})
