import process from "node:process";
import { createHighlighter, type Highlighter } from "shiki";

// --- 0. 文字幅の判定ヘルパー（East Asian Width & DSRプローブ） ---
let isEaw = true;

function getCharWidth(char: string): number {
  const code = char.codePointAt(0) ?? 0;

  // 1. 確定全角 (Wide / Fullwidth): 漢字、ひらがな、カタカナ、全角英数・記号
  if (
    (code >= 0x1100 && code <= 0x115f) ||
    (code >= 0x2e80 && code <= 0xa4cf) ||
    (code >= 0xac00 && code <= 0xd7a3) ||
    (code >= 0xf900 && code <= 0xfaff) ||
    (code >= 0xfe10 && code <= 0xfe19) ||
    (code >= 0xfe30 && code <= 0xfe6f) ||
    (code >= 0xff01 && code <= 0xff60) ||
    (code >= 0xffe0 && code <= 0xffe6)
  ) {
    return 2;
  }

  // 2. 東アジア曖昧幅 (Ambiguous Width): ギリシャ文字、キリル文字、※、★、℃、矢印など
  if (
    (code >= 0x0370 && code <= 0x03ff) || // ギリシャ文字
    (code >= 0x0400 && code <= 0x04ff) || // キリル文字
    (code >= 0x2010 && code <= 0x205e) || // 一般句読点
    (code >= 0x2100 && code <= 0x214f) || // 文字様記号 (℃ 等)
    (code >= 0x2190 && code <= 0x21ff) || // 矢印
    (code >= 0x2200 && code <= 0x22ff) || // 数学記号
    (code >= 0x25a0 && code <= 0x25ff) || // 幾何学模様 (■, ★, ○ 等)
    (code >= 0x2600 && code <= 0x26ff)    // その他記号 (※ 等)
  ) {
    return isEaw ? 2 : 1; // 端末の検知結果に応じて動的に幅を切り替え！
  }

  return 1;
}

function getStringWidth(str: string): number {
  let width = 0;
  for (const ch of Array.from(str)) {
    width += getCharWidth(ch);
  }
  return width;
}

function truncateToWidth(str: string, maxWidth: number): string {
  let curWidth = 0;
  let res = "";
  for (const ch of Array.from(str)) {
    const w = getCharWidth(ch);
    if (curWidth + w > maxWidth) break;
    res += ch;
    curWidth += w;
  }
  return res;
}

// Hexカラー (#RRGGBB) を ANSI 24-bit TrueColor エスケープコードに変換
function hexToAnsi(hex?: string): string {
  if (!hex) return "\x1b[0m";
  const clean = hex.replace("#", "").slice(0, 6);
  if (clean.length !== 6) return "\x1b[0m";
  const r = parseInt(clean.slice(0, 2), 16);
  const g = parseInt(clean.slice(2, 4), 16);
  const b = parseInt(clean.slice(4, 6), 16);
  return `\x1b[38;2;${r};${g};${b}m`;
}

// --- 1. 状態管理 (EditorState) ---
const filename = process.argv[2] ?? "untitled.ts";
let lines: string[] = [""];
let cursorX = 0;
let cursorY = 0;
let rowOffset = 0;
let isModified = false;
let statusMessage = "";

type EditorMode = "EDIT" | "QUICKRUN_VIEW";
let currentMode: EditorMode = "EDIT";

// Shiki シンタックスハイライト管理
const THEME_NAME = "nord";
const SUPPORTED_LANGS = [
  "typescript",
  "javascript",
  "python",
  "ruby",
  "php",
  "json",
  "markdown",
  "rust",
  "go",
  "bash",
  "html",
  "css",
] as const;

function detectLanguage(file: string): string | null {
  if (file.endsWith(".ts") || file.endsWith(".tsx")) return "typescript";
  if (file.endsWith(".js") || file.endsWith(".mjs")) return "javascript";
  if (file.endsWith(".py")) return "python";
  if (file.endsWith(".rb")) return "ruby";
  if (file.endsWith(".php")) return "php";
  if (file.endsWith(".json")) return "json";
  if (file.endsWith(".md")) return "markdown";
  if (file.endsWith(".rs")) return "rust";
  if (file.endsWith(".go")) return "go";
  if (file.endsWith(".sh")) return "bash";
  if (file.endsWith(".html")) return "html";
  if (file.endsWith(".css")) return "css";
  return null;
}

const currentLang = detectLanguage(filename);
let highlighter: Highlighter | null = null;
let highlightedLines: string[] = []; // キャッシュされた ANSI カラー付き行

// ファイルの読み込み
const file = Bun.file(filename);
if (await file.exists()) {
  const content = await file.text();
  const normalized = content.replace(/\r?\n$/, "");
  lines = normalized.split("\n").map((l) => l.replace(/\r$/, ""));
  if (lines.length === 0) lines = [""];
}

// Shiki インスタンスの初期化
if (currentLang) {
  try {
    highlighter = await createHighlighter({
      themes: [THEME_NAME],
      langs: [currentLang],
    });
  } catch {
    highlighter = null;
  }
}

// バッファ全体のハイライトを更新（キャッシュ）
function updateHighlight() {
  if (!highlighter || !currentLang) {
    highlightedLines = [...lines];
    return;
  }

  try {
    const code = lines.join("\n");
    const { tokens } = highlighter.codeToTokens(code, {
      lang: currentLang,
      theme: THEME_NAME,
    });

    highlightedLines = tokens.map((lineTokens) => {
      let lineAnsi = "";
      for (const tok of lineTokens) {
        lineAnsi += `${hexToAnsi(tok.color)}${tok.content}\x1b[0m`;
      }
      return lineAnsi;
    });
  } catch {
    highlightedLines = [...lines];
  }
}

// 初回ハイライト更新
updateHighlight();

const LINE_NUM_WIDTH = 4;

// --- 2. 画面サイズとスクロール ---
function getWindowSize() {
  return {
    rows: process.stdout.rows || 24,
    cols: process.stdout.columns || 80,
  };
}

function scroll() {
  const { rows } = getWindowSize();
  const screenRows = rows - 1;

  if (cursorY < rowOffset) {
    rowOffset = cursorY;
  }
  if (cursorY >= rowOffset + screenRows) {
    rowOffset = cursorY - screenRows + 1;
  }
}

// --- 3. 画面描画 (Renderer) ---
function render() {
  if (currentMode === "QUICKRUN_VIEW") return;

  scroll();

  const { rows, cols } = getWindowSize();
  const screenRows = rows - 1;

  let output = "";

  output += "\x1b[?25l";
  output += "\x1b[H";

  // 1. 各行の描画（キャッシュされた Shiki ハイライト行を使用！）
  for (let i = 0; i < screenRows; i++) {
    const fileRow = rowOffset + i;
    output += `\x1b[${i + 1};1H`;

    if (fileRow < lines.length) {
      const lineNum = (fileRow + 1).toString().padStart(3, " ");
      const renderedText = highlightedLines[fileRow] ?? lines[fileRow];
      output += `\x1b[90m${lineNum} \x1b[0m${renderedText}\x1b[K`;
    } else {
      output += `\x1b[90m  ~ \x1b[0m\x1b[K`;
    }
  }

  // 2. ステータスバー（言語とテーマのインジケータ付き）
  output += `\x1b[${rows};1H`;

  const modMark = isModified ? " [*未保存]" : "";
  const posInfo = `Ln ${cursorY + 1}/${lines.length}, Col ${cursorX + 1}`;
  const eawTag = isEaw ? ":EAW" : ":Non-EAW";
  const langTag = currentLang ? ` [${currentLang}:${THEME_NAME}${eawTag}]` : ` [${eawTag.slice(1)}]`;
  const msgPart = statusMessage ? ` | ${statusMessage}` : "";
  const leftText = ` [inzm] ${filename}${modMark}${langTag} | ${posInfo}${msgPart}`;
  const rightText = `Ctrl+R: 実行 | Ctrl+S: 保存 | Ctrl+Q: 終了 `;

  const maxBarWidth = cols - 1;
  const leftVisualWidth = getStringWidth(leftText);
  const rightVisualWidth = getStringWidth(rightText);
  const spacePadding = Math.max(0, maxBarWidth - leftVisualWidth - rightVisualWidth);
  const rawBarText = leftText + " ".repeat(spacePadding) + rightText;
  const safeBarText = truncateToWidth(rawBarText, maxBarWidth);

  output += `\x1b[7m${safeBarText}\x1b[0m\x1b[K`;

  // 3. カーソル位置の復帰
  const screenCursorY = cursorY - rowOffset + 1;
  const currentLineChars = Array.from(lines[cursorY] ?? "");
  const charsBeforeCursor = currentLineChars.slice(0, cursorX).join("");
  const visualCursorX = getStringWidth(charsBeforeCursor);
  const screenCursorX = visualCursorX + LINE_NUM_WIDTH + 1;

  output += `\x1b[${screenCursorY};${screenCursorX}H`;
  output += "\x1b[?25h";

  process.stdout.write(output);
}

// --- 4. ターミナル生モード & クリーンアップ ---
function setTitle(title: string) {
  process.stdout.write(`\x1b]0;${title}\x07`);
}

function cleanup() {
  setTitle(""); // タイトルリセット
  // 代替画面バッファを抜けて通常画面に戻し、カーソルを表示
  process.stdout.write("\x1b[?1049l\x1b[?25h");
  if (process.stdin.isTTY) {
    process.stdin.setRawMode(false);
  }
}

process.on("exit", cleanup);
process.on("SIGINT", () => process.exit(0));

process.stdout.on("resize", () => {
  render();
});

if (process.stdin.isTTY) {
  process.stdin.setRawMode(true);
}
process.stdin.resume();

setTitle(`inzm - ${filename}`);

// 代替画面バッファ (Alternate Screen Buffer) に入る
process.stdout.write("\x1b[?1049h");

// DSRプローブ: 端末の曖昧幅 (EAW) を動的自動検知
async function probeEaw(): Promise<boolean> {
  return new Promise((resolve) => {
    let done = false;
    const timeout = setTimeout(() => {
      if (!done) {
        done = true;
        resolve(true); // タイムアウト時は安全にデフォルトEAW
      }
    }, 100);

    const onData = (data: Buffer) => {
      const match = data.toString().match(/\[\d+;(\d+)R/);
      if (match) {
        done = true;
        clearTimeout(timeout);
        process.stdin.removeListener("data", onData);
        process.stdout.write("\x1b[1;1H\x1b[2K"); // 画面クリア
        resolve(parseInt(match[1], 10) === 3);
      }
    };

    process.stdin.on("data", onData);
    process.stdout.write("\x1b[1;1H\x1b[2Kα\x1b[6n");
  });
}

isEaw = await probeEaw();

render();

// --- 5. QuickRun 実行関数 ---
async function runQuickRun() {
  currentMode = "QUICKRUN_VIEW";

  const contentToSave = lines.join("\n") + "\n";
  await Bun.write(filename, contentToSave);
  isModified = false;

  let cmd: string[] = [];
  if (filename.endsWith(".ts") || filename.endsWith(".js")) {
    cmd = ["bun", "run", filename];
  } else if (filename.endsWith(".py")) {
    cmd = ["python3", filename];
  } else if (filename.endsWith(".php")) {
    cmd = ["php", filename];
  } else if (filename.endsWith(".rb")) {
    cmd = ["ruby", filename];
  } else if (filename.endsWith(".sh")) {
    cmd = ["bash", filename];
  } else {
    cmd = ["cat", filename];
  }

  process.stdout.write("\x1b[2J\x1b[H\x1b[?25l");
  const header = `\x1b[1;36m=== QuickRun: ${cmd.join(" ")} (Timeout: 5s) ===\x1b[0m\r\n\r\n`;
  process.stdout.write(header);

  const timeoutMs = 5000;
  let isTimedOut = false;
  let exitCode = 0;
  let outputText = "";

  try {
    const proc = Bun.spawn(cmd, {
      stdout: "pipe",
      stderr: "pipe",
    });

    const timer = setTimeout(() => {
      isTimedOut = true;
      proc.kill();
    }, timeoutMs);

    const [stdoutText, stderrText] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
    ]);

    clearTimeout(timer);
    exitCode = await proc.exited;

    outputText = stdoutText;
    if (stderrText) {
      outputText += (outputText ? "\n" : "") + `\x1b[31m${stderrText}\x1b[0m`;
    }
  } catch (err) {
    outputText = `\x1b[31m実行エラー: ${err}\x1b[0m`;
  }

  if (outputText) {
    const formatted = outputText.replace(/\r?\n/g, "\r\n");
    process.stdout.write(formatted + (formatted.endsWith("\r\n") ? "" : "\r\n"));
  }

  process.stdout.write("\r\n");
  if (isTimedOut) {
    process.stdout.write("\x1b[33m⚠️ タイムアウト（5秒超過のため強制終了しました）\x1b[0m\r\n");
  } else {
    const codeColor = exitCode === 0 ? "32" : "31";
    process.stdout.write(`\x1b[${codeColor}m[プロセス終了: コード ${exitCode}]\x1b[0m\r\n`);
  }
  process.stdout.write("\x1b[7m [q] または [Esc] を押すとエディタに戻ります \x1b[0m\r\n");
}

// --- 6. キー入力ハンドラ ---
process.stdin.on("data", async (data: Buffer) => {
  const key = data.toString();

  // === QuickRun 結果画面 ===
  if (currentMode === "QUICKRUN_VIEW") {
    if (key === "q" || key === "Q" || key === "\x1b" || key === "\r" || key === "\n") {
      currentMode = "EDIT";
      statusMessage = "QuickRun 完了";
      render();
    }
    if (key === "\u0003") {
      process.exit(0);
    }
    return;
  }

  // === 通常エディタモード ===

  // Ctrl+Q または Ctrl+C で終了
  if (key === "\u0011" || key === "\u0003") {
    process.exit(0);
  }

  // Ctrl+R (\u0012): QuickRun
  if (key === "\u0012") {
    await runQuickRun();
    return;
  }

  // Ctrl+S (\u0013): ファイル保存
  if (key === "\u0013") {
    try {
      const contentToSave = lines.join("\n") + "\n";
      await Bun.write(filename, contentToSave);
      isModified = false;
      statusMessage = "✅ 保存完了！";
    } catch (e) {
      statusMessage = `❌ 保存失敗: ${e}`;
    }
    render();
    return;
  }

  if (statusMessage) {
    statusMessage = "";
  }

  const currentChars = Array.from(lines[cursorY] ?? "");
  let contentChanged = false;

  // 矢印キー移動（カーソル移動時はハイライト再計算なしで超高速！）
  if (key === "\x1b[A") {
    if (cursorY > 0) {
      cursorY--;
      cursorX = Math.min(cursorX, Array.from(lines[cursorY]).length);
    }
  } else if (key === "\x1b[B") {
    if (cursorY < lines.length - 1) {
      cursorY++;
      cursorX = Math.min(cursorX, Array.from(lines[cursorY]).length);
    }
  } else if (key === "\x1b[C") {
    if (cursorX < currentChars.length) {
      cursorX++;
    } else if (cursorY < lines.length - 1) {
      cursorY++;
      cursorX = 0;
    }
  } else if (key === "\x1b[D") {
    if (cursorX > 0) {
      cursorX--;
    } else if (cursorY > 0) {
      cursorY--;
      cursorX = Array.from(lines[cursorY]).length;
    }
  }
  // Page Up（Fn+↑、物理PageUp、Alt+V 等）
  else if (
    key === "\x1b[5~" ||
    key === "\x1b[5;2~" ||
    key === "\x1b[5;5~" ||
    key === "\x1b[I" ||
    key === "\x1b[V" ||
    key === "\x1bv"
  ) {
    const { rows } = getWindowSize();
    const screenRows = rows - 1;
    cursorY = Math.max(0, cursorY - screenRows);
    cursorX = Math.min(cursorX, Array.from(lines[cursorY]).length);
  }
  // Page Down（Fn+↓、物理PageDown、Ctrl+V 等）
  else if (
    key === "\x1b[6~" ||
    key === "\x1b[6;2~" ||
    key === "\x1b[6;5~" ||
    key === "\x1b[G" ||
    key === "\x1b[U" ||
    key === "\u0016" // Ctrl+V
  ) {
    const { rows } = getWindowSize();
    const screenRows = rows - 1;
    cursorY = Math.min(lines.length - 1, cursorY + screenRows);
    cursorX = Math.min(cursorX, Array.from(lines[cursorY]).length);
  }
  // Home キー（行頭へジャンプ: 各種ターミナルシーケンス対応）
  else if (key === "\x1b[H" || key === "\x1b[1~" || key === "\x1b[7~" || key === "\x1bOH") {
    cursorX = 0;
  }
  // End キー（行末へジャンプ: 各種ターミナルシーケンス対応）
  else if (key === "\x1b[F" || key === "\x1b[4~" || key === "\x1b[8~" || key === "\x1bOF") {
    cursorX = currentChars.length;
  }
  // Enter (改行)
  else if (key === "\r" || key === "\n") {
    const before = currentChars.slice(0, cursorX).join("");
    const after = currentChars.slice(cursorX).join("");
    lines[cursorY] = before;
    lines.splice(cursorY + 1, 0, after);
    cursorY++;
    cursorX = 0;
    isModified = true;
    contentChanged = true;
  }
  // Backspace (削除)
  else if (key === "\x7f" || key === "\x08") {
    if (cursorX > 0) {
      currentChars.splice(cursorX - 1, 1);
      lines[cursorY] = currentChars.join("");
      cursorX--;
      isModified = true;
      contentChanged = true;
    } else if (cursorY > 0) {
      const prevChars = Array.from(lines[cursorY - 1]);
      const prevLen = prevChars.length;
      lines[cursorY - 1] = prevChars.join("") + currentChars.join("");
      lines.splice(cursorY, 1);
      cursorY--;
      cursorX = prevLen;
      isModified = true;
      contentChanged = true;
    }
  }
  // 通常の文字入力
  else if (!key.startsWith("\x1b") && key >= " ") {
    const inputChars = Array.from(key);
    currentChars.splice(cursorX, 0, ...inputChars);
    lines[cursorY] = currentChars.join("");
    cursorX += inputChars.length;
    isModified = true;
    contentChanged = true;
  }
  // 未知のエスケープシーケンスが押された場合のデバッグ用（押されたキーを可視化）
  else if (key.startsWith("\x1b")) {
    statusMessage = `Key: ${JSON.stringify(key)}`;
  }

  // テキスト内容が変更された場合のみハイライトを差分更新
  if (contentChanged) {
    updateHighlight();
  }

  render();
});
