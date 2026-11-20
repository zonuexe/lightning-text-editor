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

Node.jsを使用する場合（Node.js 22.18 以降 / 23.6 以降は型注釈をそのまま実行できます）:
```bash
node editor.ts
# それより古い Node.js の場合
npx tsx editor.ts
```

---

## ⌨️ ターミナル生モードとキー入力の最小コード

```typescript
// editor.ts
import process from "node:process";
import { fileURLToPath } from "node:url";

// 1. 終了時の安全対策（制御シーケンスを flush してから Cooked Mode に戻す）
function cleanup() {
  process.stdout.write("\x1b[2J\x1b[H\x1b[?25h\x1b[0m");
  if (process.stdin.isTTY) {
    process.stdin.setRawMode(false);
  }
}

// 2. 入力バッファの先頭から「1キー分」を切り出す。
//    data イベント1回 = 1キーではない（貼り付けや IME 確定は複数文字、SSH では ESC と [A が分かれて届く）
//    続きがまだ届いていなければ null（flush=true なら手元の分だけで確定させる）
export function takeKey(buf: string, flush: boolean): [string, string] | null {
  if (buf[0] !== "\x1b") {
    const ch = String.fromCodePoint(buf.codePointAt(0)!); // 絵文字（サロゲートペア）も1文字として扱う
    return [ch, buf.slice(ch.length)];
  }
  if (buf.length === 1) return flush ? ["\x1b", ""] : null; // 単独 Esc かどうかは 50ms 待って判断
  const b2 = buf[1];
  if (b2 === "\x1b" || b2.charCodeAt(0) >= 0x80) return ["\x1b", buf.slice(1)]; // Esc+矢印・Alt+日本語
  if (b2 === "O") { // SS3（F1〜F4 等）は1文字で終わる
    if (buf.length < 3) return flush ? [buf, ""] : null;
    return [buf.slice(0, 3), buf.slice(3)];
  }
  if (b2 !== "[") return [buf.slice(0, 2), buf.slice(2)]; // Alt+文字
  for (let i = 2; i < buf.length; i++) { // CSI は終端文字（0x40..0x7E）まで
    if (i === 2 && buf[i] === "[") continue; // Linux コンソールの F1〜F5（\x1b[[A 等）
    const c = buf.charCodeAt(i);
    if (c >= 0x40 && c <= 0x7e) return [buf.slice(0, i + 1), buf.slice(i + 1)];
  }
  return flush ? [buf, ""] : null;
}

function handleKey(key: string) {
  // Ctrl+Q (\x11) または Ctrl+C (\x03) で終了
  if (key === "\x11" || key === "\x03") {
    process.exit(0);
  }

  if (key === "\x1b[A") { /* 上矢印 */ }
  else if (key === "\x1b[B") { /* 下矢印 */ }
  else if (key === "\x1b[C") { /* 右矢印 */ }
  else if (key === "\x1b[D") { /* 左矢印 */ }
  else if (key === "\x1b") { /* 単独 Esc */ }
  else if (key === "\r") { /* Enter */ }
  else if (key === "\x7f" || key === "\x08") { /* Backspace */ }
  else if (key[0] === "\x1b" || key.charCodeAt(0) < 0x20) { /* 未対応の特殊キー・制御文字は無視 */ }
  else {
    // 通常の文字入力（key は1文字）
  }
}

export function runCli() {
  if (!process.stdin.isTTY || !process.stdout.isTTY) {
    console.error("Not a TTY");
    process.exit(1);
  }
  process.stdin.setRawMode(true);
  process.stdin.setEncoding("utf8"); // チャンク境界で UTF-8 が切れても文字化けしない
  process.stdin.resume();

  process.on("exit", cleanup);
  process.on("SIGINT", () => process.exit(0));
  process.on("SIGTERM", () => process.exit(0));

  // 3. キー入力の受付: 届いた文字列を溜めて、1キーずつ handleKey へ渡す
  let pending = "";
  let escTimer: ReturnType<typeof setTimeout> | undefined;
  const feed = (chunk: string, flush = false) => {
    pending += chunk;
    clearTimeout(escTimer);
    while (pending.length > 0) {
      const r = takeKey(pending, flush);
      if (!r) {
        escTimer = setTimeout(() => feed("", true), 50);
        return;
      }
      pending = r[1];
      handleKey(r[0]);
    }
  };
  process.stdin.on("data", (chunk: string) => feed(chunk));
}

// bun / node では import.meta.main が使える。tsx では undefined になるため argv と比較して判定する
const isMain = import.meta.main ?? process.argv[1] === fileURLToPath(import.meta.url);
if (isMain) {
  runCli();
}
```

---

## 💾 ファイル保存と読み込み

### Bunネイティブの場合（超シンプル）
```typescript
// 読み込み（ファイルが無ければ空バッファ。末尾の改行を1つ外してから行に分割する）
// 非 UTF-8 のファイルを text() で読むと U+FFFD に置き換わり、保存した瞬間に元のバイトが壊れるため、
// fatal: true でデコードして例外にし、開くのを中止する
const file = Bun.file("sample.txt");
const text = (await file.exists())
  ? new TextDecoder("utf-8", { fatal: true }).decode(await file.bytes())
  : "";
const lines = (text.endsWith("\n") ? text.slice(0, -1) : text).split("\n"); // 空でも [""]

// 書き込み（保存）: 末尾改行を付けて書き戻す（付けないと保存のたびに末尾改行が消える）
await Bun.write("sample.txt", lines.join("\n") + "\n");
```

### Node.js互換の場合 (`fs/promises`)
```typescript
import * as fs from "node:fs/promises";

// 読み込み（ENOENT のときだけ空バッファにする。非 UTF-8 は fatal: true で例外にして開くのを中止する）
let text = "";
try {
  text = new TextDecoder("utf-8", { fatal: true }).decode(await fs.readFile("sample.txt"));
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
4. **`data` イベント1回を1キーとみなさない／リサイズに備える**:
   - 高速なキー連打・貼り付け・IME の確定では `\x1b[A\x1b[B` や `日本語` が 1 回の `data` イベントにまとまって届き、SSH 越しでは `\x1b` と `[A` に分断されることもあります。最小コードの `takeKey` のように溜めたバッファから1キーずつ切り出し、`setEncoding("utf8")` でチャンク境界の UTF-8 の分断を防いでください。リサイズは `process.stdout.on("resize", ...)` で再描画します。
5. **サロゲートペア破壊とテスト容易性の確保（TTY 初期化の分離）**:
   - `line.length` や `line.slice()` は UTF-16 コードユニット単位のため、`🍣` 等の絵文字を壊します。`Array.from(line)`（コードポイント配列）でインデックス操作してください。
   - `EditorCore` クラスのコンストラクタで `init()`（`stdin.isTTY` 判定・`setRawMode`・`process.exit`）を即実行すると単体テストからインスタンス化できなくなります。I/O 起動は最小コードの `if (isMain) runCli()` に分離し、`EditorCore` 自身の `handleKey("d"); handleKey("d")`（`pendingKey` による 1 キーずつの状態遷移）や `:w` の実ファイル保存・`render()` 出力まで直接テストできるように設計します（参照実装: [examples/bun-ts/](../examples/bun-ts/)）。
