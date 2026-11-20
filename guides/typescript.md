# TypeScript版 クイックリファレンス (Bun / Node.js)

TypeScriptでターミナルエディタを作る場合、**Bun**を使うと設定ファイル一切不要で1秒で実行できるため最も推奨されます。もちろん、Node.js + `tsx` でも同様に動作します。

---

## ⚡️ クイックスタート（Bunの場合）

プロジェクトフォルダを作成し、単一の `.ts` ファイルを作成するだけです。

```bash
mkdir my-editor && cd my-editor
# 設定ファイル不要！
touch editor.ts
bun run editor.ts
```

Node.jsを使用する場合:
```bash
npx tsx editor.ts
```

---

## ⌨️ ターミナル生モードとキー入力の最小コード

```typescript
// editor.ts
import process from "node:process";

// 1. 終了時の安全対策（制御シーケンスを flush してから Cooked Mode に戻す）
function cleanup() {
  process.stdout.write("\x1b[2J\x1b[H\x1b[?25h\x1b[0m");
  if (process.stdin.isTTY) {
    process.stdin.setRawMode(false);
  }
}

export function runCli() {
  if (!process.stdin.isTTY || !process.stdout.isTTY) {
    console.error("Not a TTY");
    process.exit(1);
  }
  process.stdin.setRawMode(true);
  process.stdin.resume();

  process.on("exit", cleanup);
  process.on("SIGINT", () => process.exit(0));
  process.on("SIGTERM", () => process.exit(0));

  // 2. キー入力の受付
  process.stdin.on("data", (data: Buffer) => {
    const key = data.toString();

    // Ctrl+Q (\x11) または Ctrl+C (\x03) で終了
    if (key === "\u0011" || key === "\u0003") {
      process.exit(0);
    }

    // 特殊キー判定
    if (key === "\x1b[A") { /* 上矢印 */ }
    else if (key === "\x1b[B") { /* 下矢印 */ }
    else if (key === "\x1b[C") { /* 右矢印 */ }
    else if (key === "\x1b[D") { /* 左矢印 */ }
    else if (key === "\r" || key === "\n") { /* Enter */ }
    else if (key === "\x7f" || key === "\x08") { /* Backspace */ }
    else {
      // 通常の文字入力
    }
  });
}

if (import.meta.main) {
  runCli();
}
```

---

## 💾 ファイル保存と読み込み

### Bunネイティブの場合（超シンプル）
```typescript
// 読み込み（ファイルが無ければ空バッファ。末尾の改行を1つ外してから行に分割する）
const file = Bun.file("sample.txt");
const text = (await file.exists()) ? await file.text() : "";
const lines = (text.endsWith("\n") ? text.slice(0, -1) : text).split("\n"); // 空でも [""]

// 書き込み（保存）: 末尾改行を付けて書き戻す（付けないと保存のたびに末尾改行が消える）
await Bun.write("sample.txt", lines.join("\n") + "\n");
```

### Node.js互換の場合 (`fs/promises`)
```typescript
import * as fs from "node:fs/promises";

// 読み込み（ENOENT のときだけ空バッファにする）
let text = "";
try {
  text = await fs.readFile("sample.txt", "utf-8");
} catch (e) {
  if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
}
const lines = (text.endsWith("\n") ? text.slice(0, -1) : text).split("\n");

// 書き込み（保存）
await fs.writeFile("sample.txt", lines.join("\n") + "\n");
```

---

## 🎮 画面の更新（出力）

```typescript
process.stdout.write(renderedString);
```
※ `console.log` は末尾に自動で改行を入れてしまうため、エディタ画面の描画には `process.stdout.write` を使用します。

---

## ⚠️ 実装時のよくある落とし穴 (Common Pitfalls)

1. **キー入力文字列を `.trim()` してはいけない**:
   - `key.toString().trim()` を呼ぶと、スペースキー（`" "`）が空文字になって消滅し、スペースが入力できなくなります。
2. **`render()` の中で `setRawMode(false)` を呼んではいけない**:
   - 生モードの解除は **エディタ終了時（`cleanup`）のみ** 行います。描画ごとに解除すると画面表示が乱れキー入力が途切れます。
3. **改行は `\n` ではなく `\r\n` を使う**:
   - 生モード下では `\n` は「1行下がるだけ」でカーソルが左端に戻りません。必ず `\r\n` を出力します。
4. **`data` チャンクの分断・結合とリサイズに備える**:
   - 高速なキー連打や貼り付け時には `\x1b[A\x1b[B` が 1 回の `data` イベントにまとまって届いたり、SSH 越しでは `\x1b` と `[A` に分断されたりします。本番実装ではストリームパーサ（と `process.stdout.on("resize", ...)` による再描画）を組み合わせます。
5. **サロゲートペア破壊とテスト容易性の確保（TTY 初期化の分離）**:
   - `line.length` や `line.slice()` は UTF-16 コードユニット単位のため、`🍣` 等の絵文字を壊します。`Array.from(line)`（コードポイント配列）でインデックス操作してください。
   - `EditorCore` クラスのコンストラクタで `init()`（`stdin.isTTY` 判定・`setRawMode`・`process.exit`）を即実行すると単体テストからインスタンス化できなくなります。I/O 起動は `if (import.meta.main) runCli()` に分離し、`EditorCore` 自身の `handleKey("d"); handleKey("d")`（`pendingKey` による 1 キーずつの状態遷移）や `:w` の実ファイル保存・`render()` 出力まで直接テストできるように設計します（参照実装: [examples/bun-ts/](../examples/bun-ts/)）。
