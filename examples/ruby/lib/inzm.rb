# frozen_string_literal: true

require 'io/console'
require 'open3'

module Inzm
  # Emacs風のキーマップ（プレフィックスキーや階層構造をサポート）
  class Keymap
    attr_reader :bindings

    def initialize
      @bindings = {} # key_token => callable または Keymap (サブキーマップ)
    end

    def define(key_seq, &action)
      tokens = parse_sequence(key_seq)
      current = self
      tokens[0...-1].each do |tok|
        current.bindings[tok] = Keymap.new unless current.bindings[tok].is_a?(Keymap)
        current = current.bindings[tok]
      end
      current.bindings[tokens.last] = action
    end

    def [](token)
      @bindings[token]
    end

    def key?(token)
      @bindings.key?(token)
    end

    private

    # "C-x C-s", "M-:", "C-p" などの文字列表中現を正規化トークン列にパース
    def parse_sequence(seq)
      seq.split(/\s+/).map do |s|
        case s
        when /^C-([a-zA-Z])$/
          ($1.upcase.ord - 64).chr
        when /^C-([?@])$/
          "\x7f"
        when /^M-(.)$/
          "\e#{$1}"
        when "RET" then "\r"
        when "TAB" then "\t"
        when "SPC" then " "
        when "DEL" then "\x7f"
        when "ESC" then "\e"
        else s
        end
      end
    end
  end

  class Editor
    attr_accessor :lines, :cursor_x, :cursor_y, :filename, :is_modified, :status_message, :row_offset
    attr_reader :global_keymap

    LINE_NUM_WIDTH = 4

    def initialize(filename = nil)
      @filename = filename || "untitled.txt"
      @lines = [""]
      @cursor_x = 0
      @cursor_y = 0
      @row_offset = 0
      @is_modified = false
      @status_message = ""
      @running = false

      @global_keymap = Keymap.new
      @active_keymap = @global_keymap
      @prefix_keys = []

      load_file if File.exist?(@filename)
      setup_default_keybindings
      load_init_script
    end

    # --- 1. 暗黙的な init.rb のロード ---
    def load_init_script
      candidates = [
        File.expand_path("./init.rb"),
        File.expand_path("../init.rb", __dir__),
        File.expand_path("~/.inzm.rb")
      ].uniq

      candidates.each do |path|
        if File.exist?(path)
          begin
            instance_eval(File.read(path), path)
            @status_message = "Loaded #{File.basename(path)}"
          rescue => e
            @status_message = "init.rb error: #{e.message}"
          end
          break
        end
      end
    end

    # --- 2. Keymap DSL ---
    # Emacs風記法（"C-x C-s", "M-:", "C-p" など）でキーバインドを定義
    def define_key(seq, &block)
      @global_keymap.define(seq, &block)
    end

    def setup_default_keybindings
      # --- Emacs 移動コマンド ---
      define_key("C-p") { move_cursor(0, -1) } # Previous line
      define_key("C-n") { move_cursor(0, 1) }  # Next line
      define_key("C-f") { move_cursor(1, 0) }  # Forward char
      define_key("C-b") { move_cursor(-1, 0) } # Backward char
      define_key("C-a") { move_to_bol }        # Beginning of line
      define_key("C-e") { move_to_eol }        # End of line
      define_key("C-v") { move_cursor(0, screen_rows) } # Scroll down (PageDown)
      define_key("M-v") { move_cursor(0, -(screen_rows)) } # Scroll up (PageUp)

      # 矢印キー（端末標準）や各種 PageUp/PageDown もサポート
      define_key("\e[A") { move_cursor(0, -1) }
      define_key("\e[B") { move_cursor(0, 1) }
      define_key("\e[C") { move_cursor(1, 0) }
      define_key("\e[D") { move_cursor(-1, 0) }
      define_key("\e[5~")   { move_cursor(0, -(screen_rows)) }
      define_key("\e[5;2~") { move_cursor(0, -(screen_rows)) }
      define_key("\e[V")    { move_cursor(0, -(screen_rows)) }
      define_key("\e[6~")   { move_cursor(0, screen_rows) }
      define_key("\e[6;2~") { move_cursor(0, screen_rows) }
      define_key("\e[U")    { move_cursor(0, screen_rows) }

      # --- Emacs 編集コマンド ---
      define_key("C-d") { delete_forward_char } # Delete forward (Deleteキー相当)
      define_key("C-k") { kill_line }           # Kill line (行末まで削除)
      define_key("C-g") { keyboard_quit }       # Keyboard quit (キャンセル)

      # --- プレフィックスキー C-x 系列 ---
      define_key("C-x C-s") { save } # Save buffer
      define_key("C-x C-c") { quit } # Quit Emacs
      define_key("C-x u")   { @status_message = "Undo is not yet implemented" }

      # --- M-: (eval-expression) & M-! (shell-command) ---
      define_key("M-:") { prompt_eval }    # Ruby 式の eval
      define_key("M-!") { shell_command }  # シェルコマンド実行

      # スタンダードな Ctrl+S / Ctrl+Q も互換性のため残す
      define_key("C-s") { save }
      define_key("C-q") { quit }
    end

    # --- 3. ファイル I/O ---
    def load_file
      content = File.read(@filename)
      normalized = content.sub(/\r?\n\z/, "")
      @lines = normalized.split("\n").map { |l| l.delete("\r") }
      @lines = [""] if @lines.empty?
    end

    def save(target_path = nil)
      target = target_path || @filename
      begin
        File.write(target, @lines.join("\n") + "\n")
        @is_modified = false
        @status_message = "Wrote #{target}"
      rescue => e
        @status_message = "Save failed: #{e.message}"
      end
    end

    def quit
      @running = false
    end

    # --- 4. M-: (eval-expression) & M-! (shell-command) ---
    def prompt_eval
      code = prompt_input("Eval (Ruby): ")
      return if code.nil? || code.strip.empty?

      begin
        result = instance_eval(code)
        @status_message = "=> #{result.inspect}"
      rescue => e
        @status_message = "Error: #{e.message}"
      end
    end

    def shell_command
      cmd = prompt_input("Shell command: ")
      return if cmd.nil? || cmd.strip.empty?

      begin
        stdout_and_stderr, status = Open3.capture2e(cmd)
        lines = stdout_and_stderr.split("\n")

        if lines.empty?
          @status_message = "(Shell command succeeded with no output)"
        elsif lines.length == 1 && lines.first.length < (window_size[1] - 15)
          # 1行かつ短い出力なら、Emacs同様ステータスバー（エコーエリア）に表示
          @status_message = "=> #{lines.first.strip}"
        else
          # 複数行の出力なら、排他画面で *Shell Command Output* を表示
          view_shell_output(cmd, stdout_and_stderr, status.exitstatus)
        end
      rescue => e
        @status_message = "Shell error: #{e.message}"
      end
    end

    def view_shell_output(cmd, output_text, exit_code)
      print "\e[2J\e[H\e[?25l"
      header = "\e[1;36m=== Shell: #{cmd} (Exit: #{exit_code}) ===\e[0m\r\n\r\n"
      print header

      formatted = output_text.gsub(/\r?\n/, "\r\n")
      print formatted
      print "\r\n\r\n\e[7m [q], [RET], または [C-g] でエディタに戻ります \e[0m\r\n"

      loop do
        ch = $stdin.getch
        break if ch == "q" || ch == "Q" || ch == "\r" || ch == "\n" || ch == "\e" || ch == "\C-g"
      end
    end

    def keyboard_quit
      @prefix_keys.clear
      @active_keymap = @global_keymap
      @status_message = "Quit"
    end

    def prompt_input(prompt_text)
      input = ""
      rows, cols = window_size
      loop do
        prompt_line = " #{prompt_text}#{input} "
        truncated = truncate_to_width(prompt_line, cols - 1)
        print "\e[#{rows};1H\e[7m#{truncated}\e[0m\e[K"

        ch = $stdin.getch
        case ch
        when "\r", "\n"
          return input
        when "\e", "\C-c", "\C-g"
          @status_message = "Quit"
          return nil
        when "\x7f", "\x08"
          input.chop!
        else
          input << ch if ch >= " "
        end
      end
    end

    # --- 5. 文字幅計算 (簡易EAW) ---
    def char_width(char)
      code = char.ord
      if (0x1100..0x115f).include?(code) ||
         (0x2e80..0xa4cf).include?(code) ||
         (0xac00..0xd7a3).include?(code) ||
         (0xf900..0xfaff).include?(code) ||
         (0xfe10..0xfe19).include?(code) ||
         (0xfe30..0xfe6f).include?(code) ||
         (0xff00..0xff60).include?(code) ||
         (0xffe0..0xffe6).include?(code)
        2
      else
        1
      end
    end

    def string_width(str)
      str.chars.sum { |c| char_width(c) }
    end

    def truncate_to_width(str, max_width)
      curr_width = 0
      res = String.new
      str.chars.each do |c|
        w = char_width(c)
        break if curr_width + w > max_width
        res << c
        curr_width += w
      end
      res
    end

    # --- 6. 画面描画 & スクロール ---
    def window_size
      $stdout.winsize
    rescue
      [24, 80]
    end

    def screen_rows
      window_size[0] - 1
    end

    def scroll
      rows = screen_rows
      @row_offset = @cursor_y if @cursor_y < @row_offset
      @row_offset = @cursor_y - rows + 1 if @cursor_y >= @row_offset + rows
    end

    def render
      scroll
      rows, cols = window_size
      s_rows = screen_rows

      output = String.new
      output << "\e[?25l"

      # 1. 本文描画
      (0...s_rows).each do |i|
        file_row = @row_offset + i
        output << "\e[#{i + 1};1H"
        if file_row < @lines.length
          line_num = (file_row + 1).to_s.rjust(3)
          output << "\e[90m#{line_num} \e[0m#{@lines[file_row]}\e[K"
        else
          output << "\e[90m  ~ \e[0m\e[K"
        end
      end

      # 2. ステータスバー（Emacs風: -UU-:---  *inzm* ...）
      output << "\e[#{rows};1H"

      mod_mark = @is_modified ? "**" : "--"
      prefix_info = @prefix_keys.empty? ? "" : " #{@prefix_keys.join(' ')}-"
      pos_info = "L#{@cursor_y + 1}/#{@lines.length} C#{@cursor_x + 1}"
      msg_part = @status_message.empty? ? "" : "  #{@status_message}"

      left_text = "-#{mod_mark}-  [inzm] #{@filename}   (Ruby)#{prefix_info}  #{pos_info}"
      right_text = "M-:: Eval | M-!: Sh | C-x C-s: Save | C-x C-c: Quit "

      left_w = string_width(left_text)
      right_w = string_width(right_text)
      max_bar_w = cols - 1
      padding = [0, max_bar_w - left_w - right_w].max
      raw_bar = left_text + (" " * padding) + right_text

      safe_bar = truncate_to_width(raw_bar, max_bar_w)
      output << "\e[7m#{safe_bar}\e[0m\e[K"

      # 3. カーソル復帰
      screen_y = @cursor_y - @row_offset + 1
      current_chars = @lines[@cursor_y].chars
      chars_before = current_chars[0...@cursor_x]&.join || ""
      visual_x = string_width(chars_before)
      screen_x = visual_x + LINE_NUM_WIDTH + 1

      output << "\e[#{screen_y};#{screen_x}H"
      output << "\e[?25h"

      print output
    end

    # --- 7. カーソル移動 ---
    def move_to_bol
      @cursor_x = 0
    end

    def move_to_eol
      @cursor_x = @lines[@cursor_y].chars.length
    end

    def move_cursor(dx, dy)
      new_y = (@cursor_y + dy).clamp(0, @lines.length - 1)
      if new_y != @cursor_y
        @cursor_y = new_y
        @cursor_x = [@cursor_x, @lines[@cursor_y].chars.length].min
      end

      if dx != 0
        chars = @lines[@cursor_y].chars
        if dx > 0
          if @cursor_x < chars.length
            @cursor_x += 1
          elsif @cursor_y < @lines.length - 1
            @cursor_y += 1
            @cursor_x = 0
          end
        elsif dx < 0
          if @cursor_x > 0
            @cursor_x -= 1
          elsif @cursor_y > 0
            @cursor_y -= 1
            @cursor_x = @lines[@cursor_y].chars.length
          end
        end
      end
    end

    # --- 8. Emacs 編集ロジック ---
    def insert_char(char)
      chars = @lines[@cursor_y].chars
      chars.insert(@cursor_x, char)
      @lines[@cursor_y] = chars.join
      @cursor_x += 1
      @is_modified = true
    end

    def insert_newline
      chars = @lines[@cursor_y].chars
      before = chars[0...@cursor_x]&.join || ""
      after = chars[@cursor_x..]&.join || ""
      @lines[@cursor_y] = before
      @lines.insert(@cursor_y + 1, after)
      @cursor_y += 1
      @cursor_x = 0
      @is_modified = true
    end

    # Backspace (DEL)
    def delete_backward_char
      chars = @lines[@cursor_y].chars
      if @cursor_x > 0
        chars.delete_at(@cursor_x - 1)
        @lines[@cursor_y] = chars.join
        @cursor_x -= 1
        @is_modified = true
      elsif @cursor_y > 0
        prev_len = @lines[@cursor_y - 1].chars.length
        @lines[@cursor_y - 1] += @lines[@cursor_y]
        @lines.delete_at(@cursor_y)
        @cursor_y -= 1
        @cursor_x = prev_len
        @is_modified = true
      end
    end

    # C-d: カーソルの直後を1文字削除
    def delete_forward_char
      chars = @lines[@cursor_y].chars
      if @cursor_x < chars.length
        chars.delete_at(@cursor_x)
        @lines[@cursor_y] = chars.join
        @is_modified = true
      elsif @cursor_y < @lines.length - 1
        # 行末でC-dを押したら下の行と結合
        @lines[@cursor_y] += @lines[@cursor_y + 1]
        @lines.delete_at(@cursor_y + 1)
        @is_modified = true
      end
    end

    # C-k: 行末まで削除（行末なら改行を削除）
    def kill_line
      chars = @lines[@cursor_y].chars
      if @cursor_x < chars.length
        @lines[@cursor_y] = chars[0...@cursor_x].join
      elsif @cursor_y < @lines.length - 1
        @lines[@cursor_y] += @lines[@cursor_y + 1]
        @lines.delete_at(@cursor_y + 1)
      end
      @is_modified = true
    end

    # --- 9. メインループ & キーディスパッチ ---
    def run
      unless $stdin.tty?
        warn "エラー: inzm はインタラクティブな端末 (TTY) で実行してください。"
        return
      end

      # 代替画面バッファ (Alternate Screen Buffer) に入り、画面を初期化
      print "\e[?1049h\e[2J\e[H"

      @running = true

      trap("WINCH") { render if @running }

      $stdin.raw do |io|
        render
        while @running
          key = read_key(io)
          break unless key

          @status_message = "" unless @status_message.start_with?("=>", "Error", "Quit")

          # キーマップ探索
          action = @active_keymap[key]

          if action.is_a?(Keymap)
            # プレフィックスキー（例: C-x が押された）-> 次のキーを待つ
            @prefix_keys << key_name(key)
            @active_keymap = action
          elsif action.respond_to?(:call)
            # コマンド実行
            @prefix_keys.clear
            @active_keymap = @global_keymap
            instance_eval(&action)
          elsif @active_keymap != @global_keymap
            # プレフィックスキーの後に未知のキーが押された
            key_seq = (@prefix_keys + [key_name(key)]).join(" ")
            @prefix_keys.clear
            @active_keymap = @global_keymap
            @status_message = "#{key_seq} is undefined"
          else
            # 通常入力
            if key == "\r" || key == "\n"
              insert_newline
            elsif key == "\x7f" || key == "\x08"
              delete_backward_char
            elsif key >= " " && !key.start_with?("\e")
              key.chars.each { |c| insert_char(c) }
            end
          end

          render if @running
        end
      end
    ensure
      cleanup_terminal
    end

    def read_key(io)
      char = io.getch
      return nil if char.nil?

      if char == "\e"
        # Esc または Meta キー / 矢印シーケンス
        seq = String.new("\e")
        c1 = io.read_nonblock(1, exception: false)
        if c1 == :wait_readable || c1.nil?
          # 単独の Esc キー
          return "\e"
        end

        seq << c1
        if c1 == "["
          # CSI シーケンス（矢印キーなど）
          while (c = io.read_nonblock(1, exception: false))
            break if c == :wait_readable || c.nil?
            seq << c
            break if seq.length >= 3 && (c =~ /[A-Za-z~]/)
          end
          seq
        else
          # Meta キー（例: M-:, M-v, M-x など）
          seq
        end
      else
        char
      end
    end

    def key_name(k)
      case k
      when "\C-x" then "C-x"
      when "\C-c" then "C-c"
      when "\C-h" then "C-h"
      when /^\e(.)$/ then "M-#{$1}"
      else k.inspect
      end
    end

    def cleanup_terminal
      print "\e[?1049l\e[?25h"
    end
  end
end
