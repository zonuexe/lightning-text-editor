# Java版 クイックリファレンス

Javaでターミナルアプリを作る場合、デファクトスタンダードの `JLine 3` を利用するか、標準コマンドの `stty` をプロセス経由で呼び出すことでRaw Modeを実現できます。

---

## ⚡️ クイックスタート（JLine 3 推奨）

Maven または Gradle で JLine を依存に追加するのがおすすめです（参照実装 [examples/java/](../examples/java/) は Gradle 構成で、JLine ではなく `stty` 呼び出し方式を採用しています）。依存ライブラリを使わない `stty` 方式なら、`java Editor.java` の単一ファイル実行だけで試せます。

### Maven依存関係 (`pom.xml`)
```xml
<dependency>
    <groupId>org.jline</groupId>
    <artifactId>jline</artifactId>
    <version>3.25.1</version>
</dependency>
```

### Gradle (`build.gradle`)
```groovy
plugins { id 'application' }
repositories { mavenCentral() }
dependencies { implementation 'org.jline:jline:3.25.1' }
application {
    mainClass = 'Editor'
    // JDK 24+ で JLine がネイティブライブラリを読み込む際の
    // "WARNING: A restricted method ..." 表示を抑える
    applicationDefaultJvmArgs = ['--enable-native-access=ALL-UNNAMED']
}
```

`./gradlew run` は標準入力が端末に直結しないため、`./gradlew installDist` でビルドしてから `build/install/<プロジェクト名>/bin/<プロジェクト名>` を端末で直接起動してください。

---

## ⌨️ ターミナル生モードとキー入力の最小コード (JLine 3)

```java
import org.jline.terminal.Attributes;
import org.jline.terminal.Terminal;
import org.jline.terminal.TerminalBuilder;
import org.jline.utils.NonBlockingReader;

public class Editor {
    public static void main(String[] args) throws Exception {
        Terminal terminal = TerminalBuilder.builder()
                .system(true)
                .build();

        terminal.enterRawMode(); // Raw Mode 有効化（ICANON / ECHO / IEXTEN / IXON / ICRNL を無効化）
        // enterRawMode() は ISIG を残すため、Ctrl+C / Ctrl+Z / Ctrl+\ がシグナルになり
        // Ctrl+Z で生モードのまま停止してしまう。ISIG も明示的に切ってキーとして受け取る
        Attributes raw = terminal.getAttributes();
        raw.setLocalFlag(Attributes.LocalFlag.ISIG, false);
        terminal.setAttributes(raw);

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
// 読み込み（readAllLines は空ファイルで空リストを返すので、必ず1行は確保する）
// 非 UTF-8 のファイルは MalformedInputException になる。握りつぶして空バッファで開くと
// 保存した瞬間に中身が消えるため、例外は呼び出し元へ伝えて開くのを中止する
List<String> lines = Files.exists(path) ? new ArrayList<>(Files.readAllLines(path)) : new ArrayList<>();
if (lines.isEmpty()) lines.add("");

// 保存（Files.write は各行の後ろに改行を付けるので、末尾改行も保たれる）
Files.write(path, lines);
```

---

## ⚠️ 実装時のよくある落とし穴 (Common Pitfalls)

1. **単独 `Esc` キーのタイムアウト (`reader.read(50)`)**:
   - JLine の `NonBlockingReader` で `c == 27`（`\x1b`）を受け取った際、タイムアウトなしの `reader.read()` で次を読むと単独 `Esc` 押下で停止します。`reader.read(50L)` のようにミリ秒指定のタイムアウト付き読み取りを使ってください。
   - タイムアウト時の戻り値は EOF の `-1` ではなく **`-2`（`NonBlockingReader.READ_EXPIRED`）** です。`-1` だけを判定していると `-2` を文字コードとして扱ってしまうため、`c == NonBlockingReader.READ_EXPIRED` を「単独 Esc」として処理してください。
2. **リサイズ (`Terminal.Signal.WINCH`) と終了フックの `flush()`**:
   - `terminal.handle(Terminal.Signal.WINCH, ...)` でサイズ変更を検知できます。またシャットダウンフックでは必ず制御シーケンスを `flush()` してから `terminal.close()` を呼んでください（参照実装: [examples/java/](../examples/java/)）。
