-- This is an example for your LazyVim configuration.
-- Save this file as something like `~/.config/nvim/lua/plugins/fzfkasten.lua`

return {
  -- This key tells LazyVim to load the plugin from a local directory.
  -- The path should be the absolute path to your fzfkasten.nvim project.
  dir = "/home/me/fzfkasten.nvim",

  -- Add the dependencies for the plugin.
  dependencies = { "ibhagwan/fzf-lua" },

  -- The config function is where you set up the plugin.
  config = function()
    require("fzfkasten").setup({
      -- You can add your custom configuration here.
      -- For example:
      -- home = "~/my-zettelkasten",
    })
  end,
}
