# nvim の起動が遅い件 — 調査の記録

**調べ終わった。端末とのやりとりは原因ではなかった。** 以前この文書に書いていた
「擬似端末ありで 1.2 秒」は、測り方が作り出した数字だった。

実際に効いているのは三つで、いずれも端末の外にある。

| 要因 | 時間 | 性質 |
|---|---|---|
| lazy の byte code の控えが冷えた初回 | 976 ms | その日の一度だけ |
| nvim の起動そのもの | 116〜153 ms | 毎回 |
| 最初のファイルを開く | 135 ms | nvim 一つにつき一度 |

二つ目以降のファイルは 20 ms で開く。体感の「1 秒以上」は、冷えた初回 976 ms に
ttyskk の 170 ms が乗った形でほぼ説明が付く。

## 「1 秒待つ」はどこから出た数字か

nvim は起動時に端末へ問い合わせを投げ、返事を待つ。返事が来ない相手だと、諦める
までの待ちがまるごと乗る。**以前の測り方は、その「答えない相手」を自分で用意して
いた。**

- `script -qec 'nvim +q' /dev/null` の擬似端末は一切答えない
- `nvim +q > /dev/null` も同じ待ちを出す (1020 ms)
- **リダイレクトせず普通に開くと 18〜22 ms**

シェル関数の中で `$(...)` に包んで測るのも同じ罠になる。nvim の出力がパイプに
入った時点で条件が変わる。**時間を測るときは nvim の出力を画面に流したままにする。**

待ちの引き金は背景色 (OSC 11) ではなく **DA1 (`CSI c`) の未応答**だった。一つずつ
黙殺して確かめた結果が下で、DA1 だけが 1 秒を生む。

| 黙殺した問い合わせ | 時間 |
|---|---|
| なし | 91 ms |
| DECRQM | 106 ms |
| `CSI 5n` | 195 ms |
| 背景色 (OSC 11) | 121 ms |
| **DA1 (`CSI c`)** | **1089 ms** |

nvim が出す `E1568: Terminal did not respond to DSR request for 'background' color`
は、この 1 秒を待ち切った後に出る。**文言が指すもの (背景色) と実際の原因 (DA1) は
ずれている**ので、このメッセージを頼りに背景色を追っても行き止まりになる。

## 端末側は無罪

実際の経路に問い合わせを投げたところ、herdr は全て即答した。

| 問い合わせ | 返事 |
|---|---|
| DA1 / DA2 / 鍵盤 (`CSI ?u`) / 背景色 / 位置 (`CSI 6n`) / `CSI 5n` / XTVERSION | 0.0〜0.1 ms |
| XTGETTCAP | 返事なし |

XTGETTCAP だけは答えないが、**nvim はこれを投げていない**ので影響しない。
ttyskk も問い合わせと返事をそのまま通していた。実測での上乗せは 170 ms で、
これは ttyskk 自身の起動分。

herdr は内部に libghostty を抱えており、`deviceAttributesTrampoline` を持つ。
nvim は XTVERSION の名乗りで相手を見て問い合わせ方を変えるため、**切り分けに使う
擬似端末は `libghostty` と名乗らせないと本番と同じ経路にならない**。

## ファイルを開く 135 ms の中身

`:edit` に 158 ms かかるうち、**157 ms が自動コマンド**だった (`noautocmd` なら
1.0 ms)。正体は lazy の遅延読み込みで、ノートを一つ開くと 14 個が読まれる。

| 読まれるもの | 時間 | 引き金 |
|---|---|---|
| markdown-preview.nvim | 20.6 ms | `ft = markdown` |
| nvim-lspconfig | 20.4 ms | `BufReadPre` |
| mason.nvim | 5.2 ms | lspconfig の連れ |
| gitsigns / ufo / yanky / render-markdown ほか | 各 1〜4 ms | `LazyFile` 等 |

## 直したこと

`markdown-preview.nvim` から `ft = { "markdown" }` を外した (`~/.config/nvim/lua/
plugins/markdown-preview.lua`)。`cmd` の指定が元からあるので、プレビューを呼んだ
その時に読まれる。**機能は何も失わずに 20.6 ms 減る。**

## 追わないと決めたもの

- **marksman (LSP) を切る。** 実測で 8 ms しか変わらない。nvim-lspconfig と
  mason は marksman の有無に関わらず `BufReadPre` で読まれるため。markdown の
  補完と参照を失う割に合わない
- **vim の syntax を treesitter に寄せる。** 既にそうなっている。ノートのバッファは
  `syntax` が空で treesitter が動いており、fzf-lua のプレビューも treesitter が
  付いた時点で切り上げて vim syntax には落ちない (`previewer/builtin.lua:1224`)
- **fzfkasten 側の手入れ。** 開く経路に上乗せが無い。`buffer.mark` は 0 ms、
  二回目以降の `buffer.edit` は 6.1 ms で素の `:edit` の 5.5 ms と差がない。
  ピッカーが出るまでも 26 ms (一覧 10 ms + 見出しの索引 16 ms)、打鍵ごとの
  絞り込みは 4.6 ms
- **端末との往復を減らす工夫。** 上のとおり全て即答されている

## 測り方

再現するときは、**nvim の出力を画面に流したまま**測る。

```sh
s=$(date +%s%N); nvim README.md +q; e=$(date +%s%N); echo $(( (e-s)/1000000 )) ms
```

問い合わせと返事そのものを見たいなら、間に中継役を挟んで両方向を記録する。
ttyskk の記録 (`TTYSKK_DEBUG` にパスを渡す) でも往復が 16 進で残る。

```sh
env -u TTYSKK_ACTIVE TTYSKK_DEBUG=/tmp/nvim.log ttyskk -- nvim
```

どの問い合わせで待っているかを特定するには、**答える擬似端末を用意して一つずつ
黙殺する**のが早い。`--startuptime` には端末の返事待ちが出てこないうえ、ファイルを
開く分も計上されないので、この件では内訳として使えない。

## 参考

- 調査日 2026-08-02、kitty + herdr + ttyskk、distrobox (Arch) / Ubuntu ホスト
- ノートは 466 件、markdown の総量 1.1 MB (`~/zettelkasten` の 97 MB はほぼ
  `.git` と PDF・画像)
