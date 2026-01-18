-- Example LazyVim configuration for Fzfkasten.nvim
-- Path: ~/.config/nvim/lua/plugins/fzfkasten.lua

return {
  dir = "/home/me/fzfkasten.nvim",
  dependencies = { "ibhagwan/fzf-lua" },

  config = function()
    require("fzfkasten").setup({
      -- Your custom settings from telekasten can be adapted here
      home = vim.fn.expand("~/zettelkasten"),
      notes = {
        daily = {
          dir = "lognote", -- dailies = vim.fn.expand("~/zettelkasten/lognote")
          template = "templates/template_daily_note.md",
        },
        weekly = {
          dir = "lognote", -- weeklies = vim.fn.expand("~/zettelkasten/lognote")
          template = "templates/template_weekly_note.md",
        },
      },
    })
  end,

  keys = {
    -- Implemented Features
    { "<leader>zf", "<cmd>FzfKastenFindNotes<CR>", desc = "[F]ind Notes" },
    { "<leader>zT", "<cmd>FzfKastenDaily<CR>", desc = "Go [T]oday" },
    { "<leader>zg", "<cmd>FzfKastenSearchContent<CR>", desc = "[G]rep Content" },
    { "<leader>zi", "<cmd>FzfKastenInsert<CR>", desc = "[I]nsert Link" },
    { "<leader>z#", "<cmd>FzfKastenTags<CR>", desc = "Show [T]ags" },

    -- Automatic link insertion
    { mode = "i", "[[", "<cmd>FzfKastenInsert<CR>", desc = "Insert Link" },

    -- TODO: Features to be implemented
    -- { "<leader>z", "<cmd>FzfKastenPanel<CR>", desc = "Fzfkasten Panel" },
    -- { "<leader>zd", "<cmd>FzfKastenFindDaily<CR>", desc = "Find [D]aily" },
    -- { "<leader>zw", "<cmd>FzfKastenFindWeekly<CR>", desc = "Find [W]eekly" },
    -- { "<leader>zz", "<cmd>FzfKastenFollowLink<CR>", desc = "Follow Link" },
    -- { "<leader>zn", "<cmd>FzfKastenNewNote<CR>", desc = "[N]ew Note" },
    -- { "<leader>zb", "<cmd>FzfKastenShowBacklinks<CR>", desc = "Show [B]acklinks" },

    -- Out of Scope / Low Priority
    -- { "<leader>zN", "<cmd>FzfKastenNewTemplatedNote<CR>", desc = "New [N]ote from Template" },
    -- { "<leader>zy", "<cmd>FzfKastenYankNotelink<CR>", desc = "[Y]ank Note Link" },
    -- { "<leader>zc", "<cmd>FzfKastenShowCalendar<CR>", desc = "Show [C]alendar" },
    -- { "<leader>zt", "<cmd>FzfKastenToggleTodo<CR>", desc = "[T]oggle To-Do" },
  },
}
