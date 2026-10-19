#!/usr/bin/env bash
# inzm.sh - GNU Readline & Unix スタック (sed/awk) による ed/ex 風ラインエディタ
set -u

# --- 1. 一時ファイルと終了処理 ---
FILENAME="${1:-}"
BUFFER=$(mktemp /tmp/inzm_buf.XXXXXX)
TEMP_SWAP=$(mktemp /tmp/inzm_swap.XXXXXX)
MODIFIED=0
LAST_ERROR=""
SHOW_PROMPT=1
PROMPT_STR="* "

cleanup() {
    rm -f "$BUFFER" "$TEMP_SWAP"
}
trap cleanup EXIT INT TERM

# ファイルの読み込み
if [[ -n "$FILENAME" && -f "$FILENAME" ]]; then
    cat "$FILENAME" > "$BUFFER"
    BYTES=$(wc -c < "$BUFFER" | tr -d ' ')
    echo "$BYTES"
elif [[ -n "$FILENAME" ]]; then
    # 新規ファイル
    touch "$BUFFER"
    echo "?$FILENAME: No such file or directory"
    LAST_ERROR="No such file or directory"
else
    touch "$BUFFER"
fi

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

# --- 5. メイン REPL ループ (Readline 駆動) ---

QUIT_CONFIRM=0

while true; do
    prompt=""
    if (( SHOW_PROMPT == 1 )); then
        prompt="$PROMPT_STR"
    fi

    # read -e による Readline / Editline 入力
    # 上下矢印キーで履歴を呼び出し、Ctrl+A/E/K/U/R などのEmacsキーがフル動作！
    if ! IFS= read -r -e -p "$prompt" cmd; then
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

    # q / q! コマンド
    if [[ "$cmd" == "q" ]]; then
        if (( MODIFIED == 1 && QUIT_CONFIRM == 0 )); then
            set_error "Warning: buffer modified"
            QUIT_CONFIRM=1
            continue
        fi
        break
    fi
    if [[ "$cmd" == "q!" ]]; then
        break
    fi
    QUIT_CONFIRM=0

    # h / H : ヘルプ（最後の?の理由表示）
    if [[ "$cmd" == "h" ]]; then
        echo "${LAST_ERROR:-No error}"
        continue
    fi

    # P : プロンプトのトグル
    if [[ "$cmd" == "P" ]]; then
        SHOW_PROMPT=$(( 1 - SHOW_PROMPT ))
        continue
    fi

    # w : 保存
    if [[ "$cmd" =~ ^w([[:space:]]+(.+))?$ ]]; then
        target_fn="${BASH_REMATCH[2]:-}"
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

    # d : 削除
    if [[ "$cmd" =~ ^([0-9,.$%]*)d$ ]]; then
        range_part="${BASH_REMATCH[1]}"
        range_pair=$(parse_range "$range_part") || { set_error "Invalid address"; continue; }
        start=$(echo "$range_pair" | awk '{print $1}')
        end=$(echo "$range_pair" | awk '{print $2}')
        cmd_delete "$start" "$end"
        continue
    fi

    # p : 表示
    if [[ "$cmd" =~ ^([0-9,.$%]*)p$ ]]; then
        range_part="${BASH_REMATCH[1]}"
        range_pair=$(parse_range "$range_part") || { set_error "Invalid address"; continue; }
        start=$(echo "$range_pair" | awk '{print $1}')
        end=$(echo "$range_pair" | awk '{print $2}')
        cmd_print "$start" "$end" 0
        continue
    fi

    # n : 行番号付き表示
    if [[ "$cmd" =~ ^([0-9,.$%]*)n$ ]]; then
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
