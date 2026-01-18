-- minimal_init.lua

-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", -- latest stable release
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

-- Setup plugins
require("lazy").setup({
  -- Dependency
  "ibhagwan/fzf-lua",

  -- Your local plugin
  {
    dir = vim.fn.getcwd(), -- Use the current working directory
    config = function()
      require("fzfkasten").setup({
        -- You can configure the plugin here for testing
        home = "~/test_notes",
        patterns = {
          -- Use '@' for tags instead of '#'
          tag = "@@([%w_-]+)",
        },
      })
    end,
  },
})

vim.notify("Fzfkasten.nvim test config loaded!", vim.log.levels.INFO)