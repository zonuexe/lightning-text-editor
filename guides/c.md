# C言語版 クイックリファレンス

C言語でのターミナルエディタ実装は、Unix標準の `<termios.h>` を用いた低レイヤプログラミングの王道（Kiloエディタ等の系譜）です。

---

## ⚡️ クイックスタート

```bash
mkdir my-c-editor && cd my-c-editor
touch main.c
clang -Wall -Wextra main.c -o editor
./editor
```

---

## ⌨️ ターミナル生モードとキー入力の最小コード

```c
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <termios.h>

struct termios orig_termios;

void disable_raw_mode(void) {
    // 画面クリアしてカーソル表示・色リセット、その後ターミナル設定を元に戻す
    const char seq[] = "\x1b[2J\x1b[H\x1b[?25h\x1b[0m";
    write(STDOUT_FILENO, seq, sizeof(seq) - 1);
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig_termios);
}

void enable_raw_mode(void) {
    // 1. 現在の端末設定を取得
    tcgetattr(STDIN_FILENO, &orig_termios);
    // 2. 終了時に必ず元に戻すよう atexit に登録
    atexit(disable_raw_mode);

    // 3. 元の設定を完全にコピーしてからフラグを倒す！
    struct termios raw = orig_termios;
    raw.c_iflag &= ~(IXON | ICRNL | BRKINT | INPCK | ISTRIP); // フロー制御(Ctrl+S/Q)やCR->NL変換を無効化
    raw.c_lflag &= ~(ECHO | ICANON | ISIG | IEXTEN);          // エコー、カノニカルモード、Ctrl+C/Z割り込み、
                                                              // Ctrl+V/O（macOS は Ctrl+Y も）の拡張処理を無効化
    raw.c_cc[VMIN] = 1;                          // 1バイト届くまで待つ
    raw.c_cc[VTIME] = 0;

    // 4. 新しい設定を適用
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);
}

int main(void) {
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) {
        fprintf(stderr, "Not a TTY\n");
        return 1;
    }
    enable_raw_mode();
    write(STDOUT_FILENO, "\x1b[2J\x1b[H", 7);
    const char banner[] = "Cエディタ起動！ Ctrl+Q で終了\r\n";
    write(STDOUT_FILENO, banner, sizeof(banner) - 1);

    char c;
    while (1) {
        if (read(STDIN_FILENO, &c, 1) == 1) {
            // Ctrl+Q (ASCII 17, 0x11) で終了
            if (c == 17) {
                break;
            } else if (c == '\r' || c == '\n') {
                write(STDOUT_FILENO, "\r\n", 2);
            } else if (c >= 32 && c <= 126) {
                write(STDOUT_FILENO, &c, 1);
            }
        }
    }
    return 0;
}
```

---

## 💾 ファイル保存と読み込み

```c
#include <stdio.h>

// 読み込み（ファイルが無ければ空バッファで開始）
void load_file(const char *path) {
    FILE *in = fopen(path, "r");
    if (!in) return;
    char line[1024];
    while (fgets(line, sizeof(line), in)) {
        // 末尾の '\n' を取り除いてバッファに追加...
    }
    fclose(in);
}

// 保存（書き込み・クローズの失敗を必ず確認する）
int save_file(const char *path) {
    FILE *out = fopen(path, "w");
    if (!out) return -1;
    // バッファの各行を出力...
    int ok = fputs("Hello World\n", out) != EOF;
    if (fclose(out) != 0) ok = 0;
    return ok ? 0 : -1;
}
```

---

## ⚠️ 実装時のよくある落とし穴 (Common Pitfalls)

1. **`struct termios raw` は必ず `orig_termios` を代入して初期化する**:
   - `struct termios raw;` のまま未初期化でビット演算を行うと、未定義メモリの値が端末に書き込まれ、**ターミナルが完全にフリーズしてシェルごと強制終了** します。
2. **`tcsetattr` のアクション定数は `TCSAFLUSH` または `TCSANOW`**:
   - 架空の定数（`TCSASET` など）を使うとコンパイルエラーになります。標準では `TCSAFLUSH`（保留中の入出力をフラッシュして適用）を使用します。
3. **`c_iflag &= ~IXON` を忘れてはいけない**:
   - これを忘れると、`Ctrl+S` で画面出力が停止（フリーズ）し、`Ctrl+Q` を押すまで何も動かなくなります（XON/XOFFソフトウェアフロー制御）。
4. **`read()` の戻り値と `EINTR` / 単独 `Esc` タイムアウトを確認する**:
   - `read(fd, &c, 1) == 1` を確認せず `c` を処理すると、未読込のゴミ値やEOFを処理して無限ループになります。
   - `SIGWINCH`（画面サイズ変更）や `SIGTERM` を扱う場合、`read()` が `errno == EINTR` で `-1` を返すことがあるためエラー終了せず再試行します。また `\x1b` の後は `VMIN=0, VTIME=1`（100ms）や `select()` を使って単独 `Esc` キーで固まらないようにします。
