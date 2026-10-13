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

// 1. Raw Mode を有効化
if (process.stdin.isTTY) {
  process.stdin.setRawMode(true);
}
process.stdin.resume();

// 2. 終了時の安全対策（Cooked Modeに戻す）
function cleanup() {
  process.stdout.write("\x1b[2J\x1b[H\x1b[?25h"); // 画面クリア & カーソル復帰
  if (process.stdin.isTTY) {
    process.stdin.setRawMode(false);
  }
}
process.on("exit", cleanup);
process.on("SIGINT", () => process.exit(0));

// 3. キー入力の受付
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
```

---

## 💾 ファイル保存と読み込み

### Bunネイティブの場合（超シンプル）
```typescript
// 読み込み
const text = await Bun.file("sample.txt").text();

// 書き込み（保存）
await Bun.write("sample.txt", lines.join("\n"));
```

### Node.js互換の場合 (`fs/promises`)
```typescript
import * as fs from "node:fs/promises";

// 読み込み
const text = await fs.readFile("sample.txt", "utf-8");

// 書き込み（保存）
await fs.writeFile("sample.txt", lines.join("\n"));
```

---

## 🎮 画面の更新（出力）

```typescript
process.stdout.write(renderedString);
```
※ `console.log` は末尾に自動で改行を入れてしまうため、エディタ画面の描画には `process.stdout.write` を使用します。
