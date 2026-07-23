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
if vim.g.loaded_miden_masm then
  return
end
vim.g.loaded_miden_masm = 1

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
