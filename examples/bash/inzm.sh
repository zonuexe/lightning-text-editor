#!/usr/bin/env bash
# inzm.sh - GNU Readline & Unix スタック (sed/awk) による ed/ex 風ラインエディタ
set -u

# --- 1. 一時ファイルと終了処理 ---
ORIG_PWD=$(pwd)
FILENAME="${1:-}"
BUFFER=$(mktemp /tmp/inzm_buf.XXXXXX)
TEMP_SWAP=$(mktemp /tmp/inzm_swap.XXXXXX)
COMP_DIR=$(mktemp -d /tmp/inzm_comp.XXXXXX)
MODIFIED=0
LAST_ERROR=""
SHOW_PROMPT=1
PROMPT_STR="* "

cleanup() {
    cd "$ORIG_PWD" 2>/dev/null || true
    rm -f "$BUFFER" "$TEMP_SWAP"
    rm -rf "$COMP_DIR"
}
trap cleanup EXIT INT TERM

# 一時ディレクトリにexコマンド名の空ファイルを作成するハック (Readline補完用)
setup_completion_dir() {
    # 1. 補完候補となるexコマンドの空ファイル
    local ex_cmds=(write quit print number delete substitute append insert help version less view visual)
    for c in "${ex_cmds[@]}"; do
        touch "$COMP_DIR/$c"
    done

    # 2. カレントディレクトリのファイルも補完できるようにシンボリックリンクを作成
    for f in "$ORIG_PWD"/*; do
        if [[ -e "$f" ]]; then
            ln -sf "$f" "$COMP_DIR/" 2>/dev/null || true
        fi
    done
}
setup_completion_dir

# ファイルの読み込み
if [[ -n "$FILENAME" && -f "$FILENAME" ]]; then
    cat "$FILENAME" > "$BUFFER"
    BYTES=$(wc -c < "$BUFFER" | tr -d ' ')
    echo "${BYTES} bytes"
elif [[ -n "$FILENAME" ]]; then
    # 新規ファイル
    touch "$BUFFER"
    echo "?$FILENAME: No such file or directory"
    LAST_ERROR="No such file or directory"
else
    touch "$BUFFER"
fi

echo "inzm.sh: Type '?' for command list, or '?<cmd>' (e.g. ?print) for details."

get_total_lines() {
    if [[ ! -s "$BUFFER" ]]; then
        echo 0
    else
        wc -l < "$BUFFER" | tr -d ' '
    fi
}

CURRENT_LINE=$(get_total_lines)

# --- 2. Readline 履歴の有効化 ---
# Bash組み込みの履歴機能をスクリプト内で明示的に有効化
set -o history
HISTFILE=/dev/null

# --- 3. ユーティリティ関数 ---

set_error() {
    LAST_ERROR="$1"
    echo "?"
}

# 範囲のパース (例: "1,5", ", ", ".", "$", "3", 空ならカレント行)
# 返り値: START END
parse_range() {
    local range_str="$1"
    local total
    total=$(get_total_lines)

    if [[ -z "$range_str" ]]; then
        echo "$CURRENT_LINE $CURRENT_LINE"
        return 0
    fi

    if [[ "$range_str" == "," || "$range_str" == "%" ]]; then
        echo "1 $total"
        return 0
    fi

    local start=""
    local end=""

    if [[ "$range_str" =~ ^([0-9]+|\.|\$)(,([0-9]+|\.|\$))?$ ]]; then
        start="${BASH_REMATCH[1]}"
        end="${BASH_REMATCH[3]:-$start}"

        # シンボル解決
        [[ "$start" == "." ]] && start="$CURRENT_LINE"
        [[ "$start" == "$" ]] && start="$total"
        [[ "$end" == "." ]] && end="$CURRENT_LINE"
        [[ "$end" == "$" ]] && end="$total"

        echo "$start $end"
        return 0
    fi

    return 1
}

# --- 4. コマンド実装群 ---

# p / n : 行の表示
cmd_print() {
    local start="$1"
    local end="$2"
    local show_number="${3:-0}"
    local total
    total=$(get_total_lines)

    if (( total == 0 )); then
        set_error "Empty buffer"
        return 1
    fi

    if (( start < 1 || end > total || start > end )); then
        set_error "Invalid line address"
        return 1
    fi

    if (( show_number == 1 )); then
        # awk で行番号付き表示 (n コマンド)
        awk -v s="$start" -v e="$end" 'NR >= s && NR <= e { printf "%3d\t%s\n", NR, $0 }' "$BUFFER"
    else
        # sed で行表示 (p コマンド)
        sed -n "${start},${end}p" "$BUFFER"
    fi

    CURRENT_LINE="$end"
}

# a / i : テキスト追記・挿入 (単独の . で終了)
cmd_input() {
    local target_line="$1"
    local mode="$2" # 'append' or 'insert'
    local input_buf
    input_buf=$(mktemp /tmp/inzm_input.XXXXXX)

    # 複数行の入力ループ (read -e で行内編集可能)
    while IFS= read -r -e line; do
        if [[ "$line" == "." ]]; then
            break
        fi
        echo "$line" >> "$input_buf"
    done

    local input_lines
    input_lines=$(wc -l < "$input_buf" | tr -d ' ')

    if (( input_lines > 0 )); then
        local total
        total=$(get_total_lines)
        local insert_at=0

        if [[ "$mode" == "append" ]]; then
            insert_at=$target_line
        else # insert
            insert_at=$(( target_line - 1 ))
            (( insert_at < 0 )) && insert_at=0
        fi

        if (( insert_at == 0 )); then
            cat "$input_buf" "$BUFFER" > "$TEMP_SWAP" && mv "$TEMP_SWAP" "$BUFFER"
            CURRENT_LINE=$input_lines
        elif (( insert_at >= total )); then
            cat "$input_buf" >> "$BUFFER"
            CURRENT_LINE=$(( total + input_lines ))
        else
            head -n "$insert_at" "$BUFFER" > "$TEMP_SWAP"
            cat "$input_buf" >> "$TEMP_SWAP"
            tail -n "+$(( insert_at + 1 ))" "$BUFFER" >> "$TEMP_SWAP"
            mv "$TEMP_SWAP" "$BUFFER"
            CURRENT_LINE=$(( insert_at + input_lines ))
        fi
        MODIFIED=1
    fi

    rm -f "$input_buf"
}

# d : 行の削除
cmd_delete() {
    local start="$1"
    local end="$2"
    local total
    total=$(get_total_lines)

    if (( total == 0 )); then
        set_error "Empty buffer"
        return 1
    fi

    if (( start < 1 || end > total || start > end )); then
        set_error "Invalid line address"
        return 1
    fi

    # sed で削除
    sed "${start},${end}d" "$BUFFER" > "$TEMP_SWAP" && mv "$TEMP_SWAP" "$BUFFER"
    MODIFIED=1

    total=$(get_total_lines)
    if (( total == 0 )); then
        CURRENT_LINE=0
    elif (( start > total )); then
        CURRENT_LINE=$total
    else
        CURRENT_LINE=$start
    fi
}

# s/old/new/g : sed による正規表現置換
cmd_substitute() {
    local range_str="$1"
    local sed_expr="$2"
    local start end
    local range_pair
    range_pair=$(parse_range "$range_str") || { set_error "Invalid range"; return 1; }
    start=$(echo "$range_pair" | awk '{print $1}')
    end=$(echo "$range_pair" | awk '{print $2}')

    # sed で置換を実行
    sed "${start},${end}${sed_expr}" "$BUFFER" > "$TEMP_SWAP" 2>/dev/null
    if [[ $? -ne 0 ]]; then
        set_error "Substitute pattern error"
        rm -f "$TEMP_SWAP"
        return 1
    fi

    mv "$TEMP_SWAP" "$BUFFER"
    MODIFIED=1
    cmd_print "$end" "$end" 0
}

# /pattern/ : 正規表現検索 (grep -n 連携)
cmd_search() {
    local pattern="$1"
    local total
    total=$(get_total_lines)

    if (( total == 0 )); then
        set_error "Empty buffer"
        return 1
    fi

    local hit=""
    # カレント行以降から検索
    hit=$(grep -n -E "$pattern" "$BUFFER" 2>/dev/null | awk -F: -v cur="$CURRENT_LINE" '$1 > cur { print $1; exit }')
    if [[ -z "$hit" ]]; then
        # ラップアラウンド（先頭からカレント行まで）
        hit=$(grep -n -E "$pattern" "$BUFFER" 2>/dev/null | awk -F: '{ print $1; exit }')
    fi

    if [[ -n "$hit" ]]; then
        CURRENT_LINE="$hit"
        cmd_print "$CURRENT_LINE" "$CURRENT_LINE" 0
    else
        set_error "Pattern not found"
    fi
}

# w : 保存
cmd_write() {
    local target="${1:-$FILENAME}"
    if [[ -z "$target" ]]; then
        set_error "No current filename"
        return 1
    fi
    FILENAME="$target"
    cat "$BUFFER" > "$FILENAME"
    MODIFIED=0
    local bytes
    bytes=$(wc -c < "$FILENAME" | tr -d ' ')
    echo "$bytes"
}

# view / visual / less : 外部ページャー less にバッファを丸投げして全画面スクロール閲覧
cmd_view() {
    local target_line="${1:-1}"
    local total
    total=$(get_total_lines)
    if (( total == 0 )); then
        set_error "Empty buffer"
        return 1
    fi

    # アドレス指定がなければ先頭行 (1) から開くのが伝統的かつ自然な挙動
    if (( target_line < 1 )); then
        target_line=1
    elif (( target_line > total )); then
        target_line=$total
    fi

    if command -v less >/dev/null 2>&1; then
        less -N "+${target_line}" "$BUFFER"
    else
        more "$BUFFER"
    fi
}

# !cmd : 外部シェルコマンドを実行 (ed/ex 伝統のシェルエスケープ)
cmd_shell_escape() {
    local sh_cmd="$1"
    sh_cmd=$(echo "$sh_cmd" | sed 's/^[[:space:]]*//')
    if [[ -z "$sh_cmd" ]]; then
        set_error "Empty shell command"
        return 1
    fi

    # % を現在のファイル名に展開 (ex の伝統: 例: !wc -l %)
    if [[ -n "$FILENAME" ]]; then
        sh_cmd="${sh_cmd//%/$FILENAME}"
    fi

    # 外部コマンド実行
    ( eval "$sh_cmd" )
    # ed の伝統: コマンド実行完了後に '!' を1行出力
    echo "!"
}

# --- 5. ヘルプシステム (? & ?command) ---

show_general_help() {
    cat <<'EOF'
=== inzm.sh (ed/ex Line Editor) Help ===

[Concepts]
  . (dot)      Current line
  $            Last line
  , or %       All lines (1,$)
  Address      [start[,end]]command (e.g. 1,5p, ,n, 3d)

[Commands]
  print (p)       Print lines
  number (n)      Print lines with line numbers
  append (a)      Append lines after address (end with lone '.')
  insert (i)      Insert lines before address (end with lone '.')
  delete (d)      Delete lines
  substitute (s)  sed-style regex substitution (e.g. s/old/new/g)
  /pattern/       Search forward for regex pattern
  write (w)       Save buffer to file
  quit (q)        Exit editor (q! to force quit)
  view (v)        Browse buffer in pager (aliases: visual, less)
  !command        Execute shell command (e.g. !wc -l %, !date, !git diff)
  P               Toggle prompt (* ) display
  h               Show last error explanation

Type '?command' (e.g. '?print', '?substitute', '?write') for detailed help.
EOF
}

show_command_help() {
    local target="$1"
    case "$target" in
        p|print)
            cat <<'EOF'
Command: print (p)
Usage:   [range]print, [range]p
Desc:    Prints addressed lines. Updates current line to the last printed.
Examples:
  p         Print current line (.)
  3p        Print line 3
  1,5p      Print lines 1 to 5
  ,p        Print all lines (1,$)
EOF
            ;;
        n|number)
            cat <<'EOF'
Command: number (n)
Usage:   [range]number, [range]n
Desc:    Prints addressed lines with line numbers.
Examples:
  n         Print current line with line number
  ,n        Print all lines with line numbers
  3,10n     Print lines 3 through 10 with line numbers
EOF
            ;;
        a|append)
            cat <<'EOF'
Command: append (a)
Usage:   [address]append, [address]a
Desc:    Appends text after addressed line (default: current line).
         Input multiple lines, end with a single '.' on a line by itself.
Examples:
  a         Append text after current line
  $a        Append text at the end of file
  0a        Append text at the beginning of file
EOF
            ;;
        i|insert)
            cat <<'EOF'
Command: insert (i)
Usage:   [address]insert, [address]i
Desc:    Inserts text before addressed line (default: current line).
         Input multiple lines, end with a single '.' on a line by itself.
Examples:
  i         Insert text before current line
  1i        Insert text at the very top of file
EOF
            ;;
        d|delete)
            cat <<'EOF'
Command: delete (d)
Usage:   [range]delete, [range]d
Desc:    Deletes addressed lines from buffer.
Examples:
  d         Delete current line
  3d        Delete line 3
  2,5d      Delete lines 2 to 5
  ,d        Delete all lines in buffer
EOF
            ;;
        s|substitute)
            cat <<'EOF'
Command: substitute (s)
Usage:   [range]s/old/new/[flags]
Desc:    Replaces matches of 'old' with 'new' using sed regex.
         Flags: g (global replacement on line)
Examples:
  s/foo/bar/        Replace first 'foo' with 'bar' on current line
  s/foo/bar/g       Replace all 'foo' with 'bar' on current line
  ,s/foo/bar/g      Replace all 'foo' with 'bar' across whole buffer
  1,10s/old/new/g   Replace in lines 1 to 10
EOF
            ;;
        w|write)
            cat <<'EOF'
Command: write (w)
Usage:   write [filename], w [filename]
Desc:    Writes buffer to file. Displays written byte count.
Examples:
  w                 Save to current filename
  w backup.txt      Save to specified file
EOF
            ;;
        q|quit)
            cat <<'EOF'
Command: quit (q)
Usage:   quit, q, quit!, q!
Desc:    Exits editor. If buffer has unsaved changes, warns with '?' once.
Examples:
  q         Quit editor (warns if modified)
  q!        Force quit without saving changes
EOF
            ;;
        view|v|visual|less)
            cat <<'EOF'
Command: view (aliases: v, visual, less)
Usage:   [address]view, [address]v, visual, less
Desc:    Opens current buffer in pager for full-screen scrolling.
         Defaults to line 1 (top of file), or jumps to [address] if specified.
         Press 'q' inside pager to return to inzm.
Examples:
  v         Browse from line 1 (top of file)
  view      Browse from line 1
  10v       Browse starting from line 10
  $v        Browse starting from the end of file
EOF
            ;;
        '!'|sh|shell)
            cat <<'EOF'
Command: !command (Shell Escape)
Usage:   !command
Desc:    Executes an arbitrary shell command.
         '%' in the command is automatically expanded to current filename.
         Prints '!' when execution completes.
Examples:
  !date              Print current date/time
  !wc -l %           Count lines in current file
  !git status        Check git status
  !git diff %        Check changes in current file
EOF
            ;;
        *)
            echo "No help available for: $target"
            echo "Available: print, number, append, insert, delete, substitute, write, quit, view, !"
            ;;
    esac
}

# --- 6. メイン REPL ループ (Readline 駆動) ---

QUIT_CONFIRM=0

while true; do
    prompt=""
    if (( SHOW_PROMPT == 1 )); then
        prompt="$PROMPT_STR"
    fi

    # 一時ディレクトリにcdして read -e を呼ぶことで、Readline にexコマンド名をファイル名として補完させるハック！
    cd "$COMP_DIR" 2>/dev/null || true
    read_status=0
    IFS= read -r -e -p "$prompt" cmd || read_status=$?
    cd "$ORIG_PWD" 2>/dev/null || true

    if (( read_status != 0 )); then
        echo ""
        break # EOF (Ctrl+D)
    fi

    # 空行なら次へ
    [[ -z "$cmd" ]] && {
        # カレント行の次へ進む (ed の伝統動作)
        total=$(get_total_lines)
        if (( CURRENT_LINE < total )); then
            CURRENT_LINE=$(( CURRENT_LINE + 1 ))
            cmd_print "$CURRENT_LINE" "$CURRENT_LINE" 0
        fi
        continue
    }

    # 履歴に記録（上下矢印や Ctrl+R で再利用可能）
    history -s "$cmd"

    # q / quit / q! コマンド
    if [[ "$cmd" == "q" || "$cmd" == "quit" ]]; then
        if (( MODIFIED == 1 && QUIT_CONFIRM == 0 )); then
            set_error "Warning: buffer modified"
            QUIT_CONFIRM=1
            continue
        fi
        break
    fi
    if [[ "$cmd" == "q!" || "$cmd" == "quit!" ]]; then
        break
    fi
    QUIT_CONFIRM=0

    # ? : 操作体系とコマンド一覧の全体ヘルプ
    if [[ "$cmd" == "?" ]]; then
        show_general_help
        continue
    fi

    # ?command (例: ?print, ?write, ?view, ?!) : 個別コマンドの用法ヘルプ
    if [[ "$cmd" =~ ^\?([a-zA-Z!]+)$ ]]; then
        show_command_help "${BASH_REMATCH[1]}"
        continue
    fi

    # h : ed 伝統のエラー詳細理由（直前の?エラーの理由を表示）
    if [[ "$cmd" == "h" ]]; then
        echo "${LAST_ERROR:-No error}"
        continue
    fi

    # !cmd : 外部シェルコマンドを実行 (例: !date, !wc -l %, !git status)
    if [[ "$cmd" =~ ^!(.*)$ ]]; then
        cmd_shell_escape "${BASH_REMATCH[1]}"
        continue
    fi

    # view / v / visual / less / :view / :less : 外部ページャーによる全画面閲覧 (先頭または指定行から)
    if [[ "$cmd" =~ ^([0-9,.$%]*)(:)?(view|visual|v|less)$ ]]; then
        addr_part="${BASH_REMATCH[1]}"
        target_row=1
        if [[ -n "$addr_part" ]]; then
            range_pair=$(parse_range "$addr_part") && target_row=$(echo "$range_pair" | awk '{print $2}')
        fi
        cmd_view "$target_row"
        continue
    fi

    # P : プロンプトのトグル
    if [[ "$cmd" == "P" ]]; then
        SHOW_PROMPT=$(( 1 - SHOW_PROMPT ))
        continue
    fi

    # w / write : 保存
    if [[ "$cmd" =~ ^(w|write)([[:space:]]+(.+))?$ ]]; then
        target_fn="${BASH_REMATCH[3]:-}"
        cmd_write "$target_fn"
        continue
    fi

    # 単一数値ジャンプ (例: "5", "1", "$")
    if [[ "$cmd" =~ ^([0-9]+|\$|\.)$ ]]; then
        target="${BASH_REMATCH[1]}"
        total=$(get_total_lines)
        [[ "$target" == "." ]] && target="$CURRENT_LINE"
        [[ "$target" == "$" ]] && target="$total"
        cmd_print "$target" "$target" 0
        continue
    fi

    # /pattern/ : 検索
    if [[ "$cmd" =~ ^/([^/]+)/?$ ]]; then
        pattern="${BASH_REMATCH[1]}"
        cmd_search "$pattern"
        continue
    fi

    # s/old/new/flags : 置換
    if [[ "$cmd" =~ ^([0-9,.$%]*)(s[/|#].*)$ ]]; then
        range_part="${BASH_REMATCH[1]}"
        sed_part="${BASH_REMATCH[2]}"
        cmd_substitute "$range_part" "$sed_part"
        continue
    fi

    # a / i : 追記・挿入
    if [[ "$cmd" =~ ^([0-9,.$%]*)a$ ]]; then
        range_part="${BASH_REMATCH[1]}"
        range_pair=$(parse_range "$range_part") || { set_error "Invalid address"; continue; }
        target=$(echo "$range_pair" | awk '{print $2}')
        cmd_input "$target" "append"
        continue
    fi
    if [[ "$cmd" =~ ^([0-9,.$%]*)i$ ]]; then
        range_part="${BASH_REMATCH[1]}"
        range_pair=$(parse_range "$range_part") || { set_error "Invalid address"; continue; }
        target=$(echo "$range_pair" | awk '{print $1}')
        cmd_input "$target" "insert"
        continue
    fi

    # d / delete : 削除
    if [[ "$cmd" =~ ^([0-9,.$%]*)(d|delete)$ ]]; then
        range_part="${BASH_REMATCH[1]}"
        range_pair=$(parse_range "$range_part") || { set_error "Invalid address"; continue; }
        start=$(echo "$range_pair" | awk '{print $1}')
        end=$(echo "$range_pair" | awk '{print $2}')
        cmd_delete "$start" "$end"
        continue
    fi

    # p / print : 表示
    if [[ "$cmd" =~ ^([0-9,.$%]*)(p|print)$ ]]; then
        range_part="${BASH_REMATCH[1]}"
        range_pair=$(parse_range "$range_part") || { set_error "Invalid address"; continue; }
        start=$(echo "$range_pair" | awk '{print $1}')
        end=$(echo "$range_pair" | awk '{print $2}')
        cmd_print "$start" "$end" 0
        continue
    fi

    # n / number : 行番号付き表示
    if [[ "$cmd" =~ ^([0-9,.$%]*)(n|number)$ ]]; then
        range_part="${BASH_REMATCH[1]}"
        range_pair=$(parse_range "$range_part") || { set_error "Invalid address"; continue; }
        start=$(echo "$range_pair" | awk '{print $1}')
        end=$(echo "$range_pair" | awk '{print $2}')
        cmd_print "$start" "$end" 1
        continue
    fi

    # 未知のコマンド
    set_error "Unknown command"
done
