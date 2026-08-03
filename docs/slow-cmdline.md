# コマンドラインが一文字ずつしか出ない件 — 調査の記録

`<leader>kl` を押すと `:FzfKastenTaskDue ` が一文字ずつゆっくり現れる、という
症状を追った。**fzfkasten は無関係で、原因は `~/.config/nvim/lua/config/
keymaps.lua` のローマ字検索にあった。**

`:` のコマンドラインに一文字打つたびに、`/` 検索用の下見が丸ごと走っていた。
中身は ttyskk の呼び出し・`winrestview`・`matchadd`・`searchpos`・`redraw` で、
**1打鍵あたり 24 ms**。`FzfKastenTaskDue` は 16 文字なので、これがそのまま
「一文字ずつ」として見えていた。

## `?` はコマンドラインの種類ではなく「任意の1文字」

Cmdline 系 autocmd の `pattern` は**ファイル名の当てはめ (グロブ) として読まれる**。
`?` はそこでは「任意の1文字」を意味するので、次のように書くと `:` にも `=` にも
当たる。

```lua
vim.api.nvim_create_autocmd("CmdlineChanged", {
  pattern = { "/", "?" },  -- `?` が `:` にも当たる
  ...
})
```

`/` の方は文字どおり `/` にしか当たらない。**同じ autocmd で `/` は一度も発火せず
`?` だけが毎回発火していた**のが、当てはめとして読まれている証拠になった。

| 登録されていた CmdlineChanged | `:FzfKastenTaskDue` を打った間の呼ばれ方 |
|---|---|
| pattern `?` (ローマ字の下見) | 32 回・平均 **23.78 ms** |
| pattern `/` (同上) | **0 回** |
| flash.nvim | 32 回・平均 0.00 ms |
| render-markdown | 32 回・平均 0.06 ms |

## 直したこと

三つの autocmd (`CmdlineEnter` / `CmdlineChanged` / `CmdlineLeave`) を
`pattern = "*"` にして、種類の判定を callback の中へ移した。`<afile>`
(= `ev.file`) にコマンドラインの種類が一文字で入るので、それを見る。

```lua
local function is_search_event(ev)
  return ev.file == "/" or ev.file == "?"
end
```

| 打鍵から `:FzfKastenTaskDue` が出揃うまで | 時間 | 1文字あたり |
|---|---|---|
| 直す前 | 458 ms | 28 ms |
| 直した後 | 32 ms | 0.6 ms |
| 素の nvim (`--clean`) | 3 ms | — |

`/kaigi` の下見は従来どおり走る (1打鍵 30〜70 ms でローマ字変換が呼ばれる)。
`:` 側は 0.1 ms で素通りするようになった。

打鍵ごとに `winrestview` と `searchpos` が走っていたので、`:` を打っている間は
カーソルも動いていた。これも同時に止まる。

## 追いかけて外れたもの

いずれも切っても速さが変わらなかった。

- **noice.nvim / lualine** — コマンドラインの見た目を作っている側なので最初に
  疑ったが、`disable` / `hide` しても 28 ms のまま
- **render-markdown.nvim** — `CmdlineChanged` を張ってはいるが 0.06 ms
- **inccommand** — `nosplit` を空にしても変わらない
- **treesitter** — LuaJIT のサンプリングでは `highlighter.lua` が 27 %、
  treesitter の query が 11 % で上位に出るが、これは下見の中の `redraw` に
  引きずられた結果。treesitter の付かない平文でも同じ 34 ms が出る
- **端末側 (herdr・kitty)** — 擬似端末で測っても再現する
- **`<leader>kl` の作り (lazy の keys からの再生)** — `:` から手で打っても同じ

## 測り方

Vim script の `:profile` は Lua を追えないので、外から測る。

1. **擬似端末で nvim を動かし、打鍵から画面に文字が伸びる時刻を記録する。**
   端末の問い合わせ (DA1・DA2・背景色・位置・XTVERSION) には即答すること。
   答えないと起動に 1 秒乗る ([slow-startup.md](slow-startup.md))。
   画面の組み立てには pyte を使ったが、colon 区切りの SGR (`38:2:r:g:b`) を
   読めず本文として流し込むので、食わせる前に落としておく
2. **`CmdlineChanged` の callback を包んで、一つずつ実行時間を測る。**
   `nvim_get_autocmds` は `callback` を返すので、いったん全部消してから
   時間を測る関数で包んで登録し直せる。ここで犯人が一発で出た

```lua
local aus = vim.api.nvim_get_autocmds({ event = "CmdlineChanged" })
vim.api.nvim_clear_autocmds({ event = "CmdlineChanged" })
-- aus の callback を、hrtime を挟んだ関数で包んで登録し直す
```

切り分けの順としては、**まず `nvim_clear_autocmds` で `CmdlineChanged` を全部
消してみる**のが早い。これで直れば autocmd の中身、直らなければ nvim 本体
(`inccommand` 等) と分かる。

## 参考

- 調査日 2026-08-03、nvim 0.12.4、Ubuntu ホスト
- 直した先は fzfkasten ではなく `~/.config/nvim/lua/config/keymaps.lua`
  (chezmoi 管理)
