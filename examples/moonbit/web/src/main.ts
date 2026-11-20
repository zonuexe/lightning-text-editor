import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";
import "./style.css";

interface InzmWasmExports {
  init_editor(cols: number, rows: number, filename: string, content: string): string;
  load_file(filename: string, content: string): string;
  on_data(data: string): string;
  on_resize(cols: number, rows: number): string;
  get_content(): string;
  get_selected_text(): string;
  delete_selection(): string;
  get_filename(): string;
  should_quit(): boolean;
  take_save_request(): boolean;
  mark_saved(): string;
}

const DEFAULT_SAMPLE = `# inzm.mbt — MoonBit WASM/WASI Editor Sample

Hello from MoonBit in your browser!
SKK 等の直接入力系 IME・漢字変換・クリック移動・macOS ショートカット対応:

1. ブラウザアプリ (WasmGC + js-string builtins + xterm.js)
2. WASI Preview 1 CLI (wasmtime 等の WASI ランタイム)

主な操作 (macOS / ブラウザ):
- クリック / ホイール   : クリック位置へカーソル移動 / スクロール (ドラッグで範囲選択 / Shift+ドラッグでブラウザ選択)
- Cmd+S / Ctrl+S      : ブラウザ保存 (localStorage)
- Cmd+← / Cmd+→       : 行頭 / 行末 (Ctrl+A / Ctrl+E も可)
- Cmd+↑ / Cmd+↓       : ファイル先頭 / 末尾
- Option+← / Option+→ : 単語単位で移動
- Option+Backspace    : 単語削除 | Cmd+Backspace: 行頭まで削除
- Cmd+D / Ctrl+D      : 行複製 | Ctrl+K: 行カット | Ctrl+U: ペースト
- Ctrl+P/N/B/F        : 上/下/左/右 (macOS Cocoa 風移動)
- Ctrl+T              : EAW (※, ★, α 等) の 1セル / 2セル 切替
`;

const STORAGE_PREFIX = "inzm-moonbit:";
const IS_MAC = /Mac|iPhone|iPad|iPod/i.test(navigator.platform || navigator.userAgent);

const bannerEl = document.getElementById("banner")!;
const filenameLabel = document.getElementById("filename-label")!;
const fileInput = document.getElementById("file-input") as HTMLInputElement;
const btnSave = document.getElementById("btn-save")!;
const btnSample = document.getElementById("btn-sample")!;
const btnRestart = document.getElementById("btn-restart")!;
const terminalContainer = document.getElementById("terminal-container")!;

function showBanner(msg: string) {
  bannerEl.textContent = msg;
  bannerEl.classList.remove("hidden");
}

function hideBanner() {
  bannerEl.classList.add("hidden");
}

function downloadFile(filename: string, content: string) {
  const blob = new Blob([content], { type: "text/plain;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

async function loadWasm(): Promise<InzmWasmExports> {
  const wasmUrl = `${import.meta.env.BASE_URL}inzm.wasm`;
  const compileOptions = {
    builtins: ["js-string"],
    importedStringConstants: "_",
  } as WebAssembly.CompileOptions;

  const response = await fetch(wasmUrl);
  if (!response.ok) {
    throw new Error(`Failed to fetch ${wasmUrl}: ${response.status}`);
  }
  const bytes = await response.arrayBuffer();
  const mod = await WebAssembly.compile(bytes, compileOptions);
  const instance = await WebAssembly.instantiate(mod, {});
  return instance.exports as unknown as InzmWasmExports;
}

async function boot() {
  let currentInputHandledByXterm = false;
  // Reset before xterm.js's own capture-phase input listener runs on term.textarea.
  terminalContainer.addEventListener(
    "input",
    () => {
      currentInputHandledByXterm = false;
    },
    { capture: true }
  );

  const term = new Terminal({
    cursorBlink: true,
    cursorStyle: "bar",
    fontSize: 15,
    fontFamily:
      'ui-monospace, "SF Mono", Menlo, Monaco, Consolas, "Hiragino Kaku Gothic ProN", "Hiragino Sans", monospace',
    theme: {
      background: "#0f1218",
      foreground: "#eceff4",
      cursor: "#88c0d0",
    },
  });
  const fitAddon = new FitAddon();
  term.loadAddon(fitAddon);
  term.open(terminalContainer);
  fitAddon.fit();

  let wasm: InzmWasmExports;
  try {
    wasm = await loadWasm();
  } catch (err) {
    showBanner(
      `WasmGC (builtins: ["js-string"]) の初期化に失敗しました: ${
        err instanceof Error ? err.message : String(err)
      }`
    );
    return;
  }

  let activeFilename = "sample.txt";
  let exited = false;
  let isImeComposing = false;

  const handleInput = (data: string) => {
    if (exited || !data) return;
    const out = wasm.on_data(data);
    term.write(out);

    if (wasm.take_save_request()) {
      const content = wasm.get_content();
      const fname = wasm.get_filename();
      localStorage.setItem(`${STORAGE_PREFIX}${fname}`, content);
      term.write(wasm.mark_saved());
    }

    if (wasm.should_quit()) {
      exited = true;
      term.writeln("\r\n[inzm.mbt exited — click 'Restart' to reopen]");
    }
  };

  if (term.textarea) {
    term.textarea.addEventListener("compositionstart", () => {
      isImeComposing = true;
    });
    term.textarea.addEventListener("compositionend", () => {
      setTimeout(() => {
        isImeComposing = false;
      }, 0);
    });

    // Capture direct-commit IME output (e.g., AquaSKK / macSKK "aaa" -> "あああ")
    // and native printable keys that bypassed xterm.js keydown preventDefault().
    term.textarea.addEventListener("input", (ev) => {
      const inputEv = ev as InputEvent;
      if (currentInputHandledByXterm) {
        return;
      }
      if (isImeComposing || inputEv.isComposing) {
        return;
      }
      if (inputEv.inputType === "insertText" && inputEv.data) {
        handleInput(inputEv.data);
        if (term.textarea) {
          term.textarea.value = "";
        }
      }
    });
  }

  term.attachCustomKeyEventHandler((ev) => {
    // 1. Never interfere while IME is composing (kanji conversion, Ctrl+J/K, etc.)
    if (isImeComposing || ev.isComposing || ev.keyCode === 229) {
      return true;
    }

    const keyLower = ev.key.toLowerCase();

    // 2. Let printable keys (and Ctrl+J for SKK hiragana toggle on macOS) flow
    //    natively to the browser's NSTextInputClient / textarea without xterm.js
    //    calling preventDefault() on keydown/keypress (fixes SKK "aaa" -> "あああ").
    if (!ev.ctrlKey && !ev.metaKey && !ev.altKey && ev.key.length === 1) {
      return false;
    }
    if (IS_MAC && ev.ctrlKey && !ev.metaKey && !ev.altKey && keyLower === "j") {
      return false;
    }

    if (ev.type !== "keydown") {
      return true;
    }

    // 3. macOS Command (metaKey) shortcuts
    if (ev.metaKey && !ev.ctrlKey && !ev.altKey) {
      if (keyLower === "s") {
        ev.preventDefault();
        handleInput("\x13"); // Save
        return false;
      }
      if (keyLower === "a") {
        ev.preventDefault();
        handleInput("\x1b[97;9u"); // Select all
        return false;
      }
      if (keyLower === "d") {
        ev.preventDefault();
        handleInput("\x04"); // Duplicate line
        return false;
      }
      if (keyLower === "c") {
        const selected = wasm.get_selected_text();
        if (selected) {
          ev.preventDefault();
          void navigator.clipboard?.writeText(selected);
          return false;
        }
        if (term.hasSelection()) {
          ev.preventDefault();
          void navigator.clipboard?.writeText(term.getSelection());
          term.clearSelection();
          return false;
        }
        return true;
      }
      if (keyLower === "x") {
        const selected = wasm.get_selected_text();
        if (selected) {
          ev.preventDefault();
          void navigator.clipboard?.writeText(selected);
          term.write(wasm.delete_selection());
          return false;
        }
      }
      if (ev.key === "ArrowLeft") {
        ev.preventDefault();
        handleInput(ev.shiftKey ? "\x1b[1;2H" : "\x1b[H");
        return false;
      }
      if (ev.key === "ArrowRight") {
        ev.preventDefault();
        handleInput(ev.shiftKey ? "\x1b[1;2F" : "\x1b[F");
        return false;
      }
      if (ev.key === "ArrowUp") {
        ev.preventDefault();
        handleInput(ev.shiftKey ? "\x1b[1;6H" : "\x1b[1;5H");
        return false;
      }
      if (ev.key === "ArrowDown") {
        ev.preventDefault();
        handleInput(ev.shiftKey ? "\x1b[1;6F" : "\x1b[1;5F");
        return false;
      }
      if (ev.key === "Backspace") {
        ev.preventDefault();
        handleInput("\x1b[127;9u"); // Delete to line start
        return false;
      }
      // Let Cmd+V (paste), Cmd+R (reload), Cmd+W/T pass through natively
      return true;
    }

    // 4. macOS Option (altKey) word-level editing (leave Option+char like Option+¥ -> '\' intact)
    if (ev.altKey && !ev.metaKey && !ev.ctrlKey) {
      if (ev.key === "ArrowLeft") {
        ev.preventDefault();
        handleInput(ev.shiftKey ? "\x1b[1;4D" : "\x1b[1;3D");
        return false;
      }
      if (ev.key === "ArrowRight") {
        ev.preventDefault();
        handleInput(ev.shiftKey ? "\x1b[1;4C" : "\x1b[1;3C");
        return false;
      }
      if (ev.key === "Backspace") {
        ev.preventDefault();
        handleInput("\x1b\x7f");
        return false;
      }
      if (ev.key === "Delete") {
        ev.preventDefault();
        handleInput("\x1bd");
        return false;
      }
    }

    // 5. Prevent browser defaults for Ctrl shortcuts (including macOS Cocoa Ctrl+P/N/B/F)
    if (ev.ctrlKey && !ev.metaKey && !ev.altKey) {
      if (
        ["s", "d", "k", "u", "q", "a", "e", "p", "n", "b", "f", "l", "h"].includes(
          keyLower
        )
      ) {
        ev.preventDefault();
      }
    }

    return true;
  });

  const startEditor = (filename: string, content: string) => {
    hideBanner();
    exited = false;
    activeFilename = filename;
    filenameLabel.textContent = filename;
    fitAddon.fit();
    const frame = wasm.init_editor(term.cols, term.rows, filename, content);
    term.write(frame);
    term.focus();
  };

  const savedContent = localStorage.getItem(`${STORAGE_PREFIX}${activeFilename}`);
  startEditor(activeFilename, savedContent ?? DEFAULT_SAMPLE);

  term.onData((data) => {
    currentInputHandledByXterm = true;
    handleInput(data);
  });

  term.onResize(({ cols, rows }) => {
    if (exited) return;
    term.write(wasm.on_resize(cols, rows));
  });

  terminalContainer.addEventListener("mousedown", () => {
    term.focus();
  });

  window.addEventListener("resize", () => {
    fitAddon.fit();
  });

  fileInput.addEventListener("change", async () => {
    const file = fileInput.files?.[0];
    if (!file) return;
    const text = await file.text();
    if (exited) {
      startEditor(file.name, text);
    } else {
      activeFilename = file.name;
      filenameLabel.textContent = file.name;
      term.write(wasm.load_file(file.name, text));
      term.focus();
    }
    fileInput.value = "";
  });

  btnSave.addEventListener("click", () => {
    const content = wasm.get_content();
    const fname = wasm.get_filename();
    localStorage.setItem(`${STORAGE_PREFIX}${fname}`, content);
    downloadFile(fname, content);
    if (!exited) {
      term.write(wasm.mark_saved());
      term.focus();
    }
  });

  btnSample.addEventListener("click", () => {
    localStorage.removeItem(`${STORAGE_PREFIX}sample.txt`);
    startEditor("sample.txt", DEFAULT_SAMPLE);
  });

  btnRestart.addEventListener("click", () => {
    const content = exited
      ? localStorage.getItem(`${STORAGE_PREFIX}${activeFilename}`) ?? DEFAULT_SAMPLE
      : wasm.get_content();
    startEditor(activeFilename, content);
  });
}

boot();
