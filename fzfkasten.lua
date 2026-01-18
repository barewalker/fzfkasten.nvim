-- ~/.config/nvim/lua/plugins/fzfkasten.lua

return {
  "your_github_username/fzfkasten.nvim", -- Replace with the actual plugin path if different
  config = function()
    require("fzfkasten").setup({
      -- Customize the home directory for your Zettelkasten notes
      -- home = "~/zettelkasten",

      -- Set the default file extension for new notes
      -- extension = "md",

      -- Configure the human-readable date format for {{hdate}}
      -- For "Thursday, January 15th, 2026", a custom function is needed for the ordinal suffix.
      -- For "Thursday, January 15, 2026", use:
      hdate_format = "%A, %B %d, %Y",

      -- Configuration for daily notes
      notes = {
        daily = {
          -- Directory for daily notes, relative to 'home'
          -- dir = "daily",
          -- Date format for filename (e.g., 2026-01-18)
          -- format = "%Y-%m-%d",
          -- Path to a template file, relative to 'home'
          -- template = "templates/daily.md",
          -- Example of using an external command for content (e.g., gcalcli agenda)
          -- use_external_cmd = false,
          -- external_cmd = "gcalcli agenda --tsv",
        },
        -- Configuration for weekly notes
        weekly = {
          -- dir = "weekly",
          -- format = "%Y-W%V",
          -- template = "templates/weekly.md",
        },
      },

      -- Custom transformations for file names or links
      -- transform = {
      --   insert_link = function(filename)
      --     return string.format("[[%s]]", filename)
      --   end,
      --   new_file_name = function(title)
      --     return title:lower():gsub(" ", "-") -- Example: "My New Note" -> "my-new-note"
      --   end,
      -- },

      -- FZF-lua specific options
      -- fzf = {
      --   winopts = {
      --     height = 0.85,
      --     width = 0.80,
      --     preview = { layout = "vertical" },
      --   },
      --   fzf_opts = {
      --     ["--bind"] = "ctrl-h:backward-delete-char",
      --   },
      --   files = {
      --     previewer = "builtin",
      --   },
      -- },
    })
  end,
}