Gemini CLIに読み込ませるための、設計思想から実装コード、テスト手順までを網羅したオールインワンの指示書を作成しました。

この内容を `fzfkasten_spec.md` という名前で保存し、Gemini CLIに「このファイルを読んで、各ディレクトリとファイルを作成して」と指示してください。

---

# Fzfkasten.nvim 実装・生成指示書

## ディレクトリ構成

fzfkasten.nvim/
├── lua/
│ └── fzfkasten/
│ ├── init.lua -- 公開API
│ ├── config.lua -- ユーザー設定管理
│ ├── core.lua -- ノート作成・テンプレート・外部連携
│ ├── pickers.lua -- fzf-lua UIの実装
│ └── utils.lua -- パス結合などの共通関数（今回新設）
├── plugin/
│ └── fzfkasten.lua -- Vimコマンドの登録
├── doc/
│ └── fzfkasten.txt -- ヘルプドキュメント（vimdoc）
└── README.md -- 導入ガイド

## 1. プロジェクト概要

**Fzfkasten.nvim** は、`fzf-lua` をコアエンジンとした、Neovim用の超軽量かつ高速なZettelkasten（ノート管理）プラグインです。既存の `telekasten.nvim` における「動作の重さ」や「設定の決め打ち（ハードコード）」を排除し、ユーザーが全ての挙動（タグ記法、リンク形式、ディレクトリ構成）を制御できることを目的としています。

## 2. コア設計指針

- **依存:** `ibhagwan/fzf-lua` および `ripgrep` (rg)。
- **脱・決め打ち:** 正規表現、日付フォーマット、リンク挿入形式を全て関数や変数として `config` で管理する。
- **LazyVim対応:** `setup` 関数と `opts` による設定を分離し、遅延読み込みを最適化する。
- **外部拡張性:** ノート作成時に Google Calendar (gcalcli等) からデータを取得できるフックを実装する。

## 3. ファイル構造と実装内容

### ファイル 1: `lua/fzfkasten/config.lua`

- デフォルト設定の定義とユーザー設定のマージ。
- `patterns.tag` にはタグ抽出の正規表現。
- `transform.insert_link` にはリンク文字列生成関数。
- 各ノート種別（daily, weekly）の設定（ディレクトリ、フォーマット、テンプレートパス、外部コマンド）。

### ファイル 2: `lua/fzfkasten/utils.lua`

- `join_path`: パスを安全に結合するヘルパー関数。

### ファイル 3: `lua/fzfkasten/core.lua`

- `open_note(type)`: 指定されたノートを開く。存在しなければディレクトリ作成＋テンプレート適用。
- `insert_template(rel_path, title)`: テンプレート内の `{{title}}` と `{{date}}` を置換。
- 外部コマンド実行フックによる内容挿入。

### ファイル 4: `lua/fzfkasten/pickers.lua`

- `find_notes()`: `fzf-lua` を使ったファイル検索（画像プレビュー対応）。
- `search_tags()`: `rg` と `fzf-lua` を使ったタグ抽出検索。
- `insert_link()`: ファイルを選択し、`config.transform.insert_link` を通してカーソル位置に挿入。

### ファイル 5: `lua/fzfkasten/init.lua`

- 各モジュールの関数を公開。
- Lazy Loadingを損なわない関数の公開方法。

### ファイル 6: `plugin/fzfkasten.lua`

- 全ての主要機能を Vim コマンド（`FzfKastenDaily` 等）として登録。

---

## 4. Gemini CLI への具体的命令

以下のコードブロックの内容を、指定のパスにそれぞれ出力してください。

```lua
-- [[ lua/fzfkasten/config.lua ]]
local M = {}

M.defaults = {
 -- 優先順位: 環境変数 > デフォルト値 (~/notes)
 home = os.getenv("ZETTELKASTEN_HOME") or vim.fn.expand("~/notes"),
 extension = "md",
 patterns = {
  tag = [[#([%w_-]+)]],
  link = [[%[%[(.-)%]%]],
 },
 notes = {
  daily = {
   dir = "daily",
   format = "%Y-%m-%d",
   template = "templates/daily.md",
   use_external_cmd = false,
   external_cmd = "gcalcli agenda --tsv",
  },
  weekly = {
   dir = "weekly",
   format = "%Y-W%V",
   template = "templates/weekly.md",
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
 fzf = {
  winopts = {
   height = 0.85,
   width = 0.80,
   preview = { layout = "vertical" },
  },
  files = {
   previewer = "builtin",
  },
 },
}

M.options = {}

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

-- [[ lua/fzfkasten/utils.lua ]]
local M = {}
function M.join_path(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end
return M

-- [[ lua/fzfkasten/core.lua ]]
local M = {}
local config = require('fzfkasten.config')
local utils = require('fzfkasten.utils')
local function get_external_content(cmd)
    local handle = io.popen(cmd)
    if not handle then return "" end
    local result = handle:read("*a")
    handle:close()
    return result
end
function M.open_note(note_type)
    local opts = config.options.notes[note_type]
    local date_str = os.date(opts.format)
    local filename = config.options.transform.new_file_name(date_str) .. "." .. config.options.extension
    local target_dir = utils.join_path(config.options.home, opts.dir)
    local full_path = utils.join_path(target_dir, filename)
    if vim.fn.isdirectory(target_dir) == 0 then vim.fn.mkdir(target_dir, "p") end
    local is_new = vim.fn.filereadable(full_path) == 0
    vim.cmd("edit " .. full_path)
    if is_new then
        local content = ""
        if opts.template then content = M.load_template(opts.template, date_str) end
        if opts.use_external_cmd and opts.external_cmd then
            content = content .. "\n## External Data\n" .. get_external_content(opts.external_cmd)
        end
        vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(content, "\n"))
    end
end
function M.load_template(rel_path, title)
    local abs_path = utils.join_path(config.options.home, rel_path)
    if vim.fn.filereadable(abs_path) == 0 then return "# " .. title end
    local data = table.concat(vim.fn.readfile(abs_path), "\n")
    return data:gsub("{{title}}", title):gsub("{{date}}", os.date("%Y-%m-%d"))
end
return M

-- [[ lua/fzfkasten/pickers.lua ]]
local fzf = require('fzf-lua')
local config = require('fzfkasten.config')
local M = {}
function M.find_notes()
    fzf.files(vim.tbl_deep_extend("force", config.options.fzf.files, {
        cwd = config.options.home, prompt = "Notes> "
    }))
end
function M.search_tags()
    fzf.grep(vim.tbl_deep_extend("force", config.options.fzf, {
        search = config.options.patterns.tag,
        cwd = config.options.home,
        prompt = "Tags> ",
        rg_opts = "--column --line-number --no-heading --color=always --smart-case --only-matching -e",
    }))
end
function M.insert_link()
    fzf.files(vim.tbl_deep_extend("force", config.options.fzf.files, {
        cwd = config.options.home,
        actions = {
            ['default'] = function(selected)
                local file = vim.fn.fnamemodify(selected[1], ":t:r")
                vim.api.nvim_put({ config.options.transform.insert_link(file) }, "c", true, true)
            end
        }
    }))
end
return M

-- [[ lua/fzfkasten/init.lua ]]
local M = {}
function M.setup(opts) require('fzfkasten.config').setup(opts) end
M.goto_daily = function() require('fzfkasten.core').open_note("daily") end
M.goto_weekly = function() require('fzfkasten.core').open_note("weekly") end
M.find_notes = function() require('fzfkasten.pickers').find_notes() end
M.search_tags = function() require('fzfkasten.pickers').search_tags() end
M.insert_link = function() require('fzfkasten.pickers').insert_link() end
return M

-- [[ plugin/fzfkasten.lua ]]
local cmd = vim.api.nvim_create_user_command
cmd("FzfKastenDaily", function() require('fzfkasten').goto_daily() end, { desc = "Fzfkasten: Daily Note" })
cmd("FzfKastenWeekly", function() require('fzfkasten').goto_weekly() end, { desc = "Fzfkasten: Weekly Note" })
cmd("FzfKastenSearch", function() require('fzfkasten').find_notes() end, { desc = "Fzfkasten: Search Notes" })
cmd("FzfKastenTags", function() require('fzfkasten').search_tags() end, { desc = "Fzfkasten: Search Tags" })
cmd("FzfKastenInsert", function() require('fzfkasten').insert_link() end, { desc = "Fzfkasten: Insert Link" })

```

---

## 5. README.md 生成依頼

- 以下の内容を `README.md` として生成してください。
- インストール方法（LazyVimスタイル）、全設定項目、Googleカレンダー(gcalcli)との連携方法、画像プレビューの利用条件を記述。

---

**準備が整いました。この指示書を読み込ませて、あなたの最強のノート管理ツール「Fzfkasten.nvim」を誕生させましょう！**
他にも追加したい特殊な処理（バックリンク自動抽出など）が必要になったら、いつでも声をかけてください。
