# Java版 クイックリファレンス

Javaでターミナルアプリを作る場合、デファクトスタンダードの `JLine 3` を利用するか、標準コマンドの `stty` をプロセス経由で呼び出すことでRaw Modeを実現できます。

---

## ⚡️ クイックスタート（JLine 3 推奨）

Maven または Gradle を使うか、単一スクリプト（Java 22+のJBang等）で動かすのがおすすめです。

### Maven依存関係 (`pom.xml`)
```xml
<dependency>
    <groupId>org.jline</groupId>
    <artifactId>jline</artifactId>
    <version>3.25.1</version>
</dependency>
```

---

## ⌨️ ターミナル生モードとキー入力の最小コード (JLine 3)

```java
import org.jline.terminal.Terminal;
import org.jline.terminal.TerminalBuilder;
import org.jline.utils.NonBlockingReader;

public class Editor {
    public static void main(String[] args) throws Exception {
        Terminal terminal = TerminalBuilder.builder()
                .system(true)
                .build();

        terminal.enterRawMode(); // Raw Mode 有効化

        // 終了時クリーンアップ
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            terminal.writer().print("\033[2J\033[H\033[?25h");
            terminal.writer().flush();
            try {
                terminal.close();
            } catch (Exception ignored) {}
        }));

        terminal.writer().print("\033[2J\033[HJavaエディタ起動！ Ctrl+Q で終了\r\n");
        terminal.writer().flush();

        NonBlockingReader reader = terminal.reader();
        while (true) {
            int c = reader.read();
            if (c == -1) { // EOF
                break;
            }

            // Ctrl+Q (17) または Ctrl+C (3) で終了
            if (c == 17 || c == 3) {
                break;
            }

            // 特殊キーや文字の処理
            if (c == '\r' || c == '\n') {
                // Enter
            } else if (c == 127 || c == 8) {
                // Backspace
            } else {
                // 文字入力
            }
        }

        System.exit(0);
    }
}
```

---

## 💾 ファイル保存と読み込み (Java NIO)

```java
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.ArrayList;

Path path = Path.of("sample.txt");
List<String> lines = Files.exists(path) ? Files.readAllLines(path) : new ArrayList<>(List.of(""));

// 保存
Files.write(path, lines);
```

---

## ⚠️ 実装時のよくある落とし穴 (Common Pitfalls)

1. **単独 `Esc` キーのタイムアウト (`reader.read(50)`)**:
   - JLine の `NonBlockingReader` で `c == 27`（`\x1b`）を受け取った際、タイムアウトなしの `reader.read()` で次を読むと単独 `Esc` 押下で停止します。`reader.read(50L)` のようにミリ秒指定のタイムアウト付き読み取りを使ってください。
2. **リサイズ (`Terminal.Signal.WINCH`) と終了フックの `flush()`**:
   - `terminal.handle(Terminal.Signal.WINCH, ...)` でサイズ変更を検知できます。またシャットダウンフックでは必ず制御シーケンスを `flush()` してから `terminal.close()` を呼んでください（参照実装: [examples/java/](../examples/java/)）。
