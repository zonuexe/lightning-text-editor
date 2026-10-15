# init.rb - inzm のカスタマイズ設定ファイル
# このファイルは起動時にエディタインスタンス（Inzm::Editor）のコンテキストで評価されます。

# 1. 独自コマンド: M-u (Meta+u) で現在行を大文字に変換！
define_key("M-u") do
  lines[cursor_y].upcase!
  self.is_modified = true
  self.status_message = "✨ Uppercased line!"
end

# 2. 独自コマンド: C-x d で行複製
define_key("C-x d") do
  lines.insert(cursor_y + 1, lines[cursor_y].dup)
  self.cursor_y += 1
  self.is_modified = true
  self.status_message = "📋 Line duplicated"
end

# 3. 独自コマンド: C-x k で現在バッファをクリア（空にする）
define_key("C-x k") do
  self.lines = [""]
  self.cursor_x = 0
  self.cursor_y = 0
  self.is_modified = true
  self.status_message = "🧹 Buffer cleared"
end

# 4. 起動時のステータス通知
self.status_message = "🚀 Loaded ~/.inzm.rb (Emacs mode enabled)"
