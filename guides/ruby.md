# Ruby版 クイックリファレンス

Rubyは標準ライブラリの `io/console` が極めて強力で、**外部gemのインストール一切なし（Pure Ruby）**でエディタを実装できます。ブロックを抜けたときに自動で通常モードへ復帰する安全機構も備わっています。

---

## ⚡️ クイックスタート

```bash
mkdir my-ruby-editor && cd my-ruby-editor
touch editor.rb
ruby editor.rb
```

---

## ⌨️ ターミナル生モードとキー入力の最小コード

```ruby
# editor.rb
require 'io/console'

def cleanup
  $stdout.write "\e[2J\e[H\e[?25h\e[0m" # 画面クリア & カーソル再表示 & 装飾リセット
  $stdout.flush
end

# $stdin.raw ブロック内は自動的に生モードになり、
# 例外発生や終了時には自動でCooked Modeに戻る
$stdin.raw do |io|
  begin
    cleanup
    $stdout.write "エディタ起動！ Ctrl+Q で終了\r\n"
    $stdout.flush

    loop do
      char = io.getch

      # Ctrl+Q (\x11) または Ctrl+C (\x03) で終了
      break if char == "\x11" || char == "\x03"

      # エスケープシーケンス（矢印キーなど）のハンドリング
      if char == "\e"
        seq1 = IO.select([io], nil, nil, 0.05) ? io.read_nonblock(1, exception: false) : nil
        seq2 = (seq1 == "[" && IO.select([io], nil, nil, 0.05)) ? io.read_nonblock(1, exception: false) : nil

        case seq2
        when "A" then # 上矢印
        when "B" then # 下矢印
        when "C" then # 右矢印
        when "D" then # 左矢印
        end
      elsif char == "\r" || char == "\n"
        # 改行処理
      elsif char == "\x7f" || char == "\x08"
        # Backspace
      else
        # 通常の文字入力
      end
    end
  ensure
    cleanup # Cooked Mode へ戻る前に必ず制御シーケンスを flush する
  end
end
```

---

## 💾 ファイル保存と読み込み

Ruby標準の `File` クラスで1行で完結します。

```ruby
# 読み込み
lines = File.exist?("sample.txt") ? File.readlines("sample.txt", chomp: true) : [""]

# 書き込み（保存）
File.write("sample.txt", lines.join("\n") + "\n")
```

---

## 💡 Rubyならではの書きやすさポイント
- `io.getch` は1文字ずつ同期的にブロックして待つため、イベントループを単純な `loop { ... }` で書くことができます。
- 文字列操作（`String#insert` や `String#slice!`、配列操作）が直感的で、バッファ操作ロジックを短く書けます。

---

## ⚠️ 実装時のよくある落とし穴 (Common Pitfalls)

1. **`$stdin.raw do |io|` のスコープ外に `io` を持ち出さない**:
   - 生モードの有効範囲はブロックの内部だけです。ブロック外で `io.getch` を呼ぼうとするとエラーや通常モード化の原因になります。
2. **文字の挿入・削除は `String#chars` を意識する**:
   - `String#[]` のバイトインデックス操作を避け、文字単位の配列や `insert` / `slice!` で安全に操作しましょう。
3. **改行の出力は `print "\r\n"` を徹底する**:
   - `puts` は端末生モード下では `\r` を伴わない場合があるため、明示的に `print "...\r\n"` を使用します。
4. **`\e` 後の `read_nonblock` と `WINCH` / `TERM` シグナル**:
   - SSH 越し等で `\e` と `[A` が別パケットで届くと直後の `read_nonblock` で取りこぼすことがあるため、`IO.select([io], nil, nil, 0.05)` で短時間待ってから判定すると安定します。また `Signal.trap("WINCH")` でリサイズ検知する場合は、ハンドラ内ではフラグ更新に留めてメインループ側で再描画します（参照実装: [examples/ruby/](../examples/ruby/)）。
