local M = {}

M.defaults = {
 -- 優先順位: 環境変数 > デフォルト値 (~/notes)
 home = os.getenv("ZETTELKASTEN_HOME") or vim.fn.expand("~/notes"),
 extension = "md",
 hdate_format = "%B %d, %Y",
 new_note_template = nil,
   patterns = {
     tag = [[#([%w_-]+)]],
     link = [=[%[%[(.-)%]%]]=],
   }, notes = {
  daily = {
   dir = "daily",
   format = "%Y-%m-%d",
   template = "daily.md",
   use_external_cmd = false,
   external_cmd = "gcalcli agenda --tsv",
   fzf_opts = {},
  },
  weekly = {
   dir = "weekly",
   format = "%Y-W%V",
   template = "weekly.md",
   fzf_opts = {},
  },
 },
 transform = {
  insert_link = function(filename)
   return string.format("[[%s]]", filename)
  end,
  new_file_name = function(title)
   return title
  end,
 },
 claude = {
  enabled = false,
 },
 fzf = {
  winopts = {
   height = 0.85,
   width = 0.80,
   preview = { layout = "vertical" },
  },
  fzf_opts = {
    ["--bind"] = "ctrl-h:backward-delete-char",
  },
  files = {
   previewer = "builtin",
  },
 },
}

M.options = vim.tbl_deep_extend("force", M.defaults, {})

function M.setup(user_opts)
 -- M.defaults と user_opts をマージ
 M.options = vim.tbl_deep_extend("force", M.defaults, user_opts or {})

 -- パスの展開 (~ をフルパスに変換)
 M.options.home = vim.fn.expand(M.options.home)

 -- 未設定時のバリデーション
 if M.options.home == "" then
  vim.notify("[Fzfkasten] 'home' directory is not configured!", vim.log.levels.ERROR)
  return
 end
end

return M