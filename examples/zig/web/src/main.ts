import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";
import "./style.css";

interface ZigWasmExports {
  memory: WebAssembly.Memory;
  wasm_in_ptr(): number;
  wasm_in_cap(): number;
  wasm_fname_ptr(): number;
  wasm_out_ptr(): number;
  wasm_content_ptr(): number;
  wasm_content_len(): number;
  wasm_selected_ptr(): number;
  wasm_selected_len(): number;
  wasm_delete_selected(): number;
  wasm_should_quit(): number;
  wasm_take_save_request(): number;
  wasm_init(cols: number, rows: number, fnameLen: number, contentLen: number): number;
  wasm_load_file(fnameLen: number, contentLen: number): number;
  wasm_on_data(dataLen: number): number;
  wasm_on_resize(cols: number, rows: number): number;
  wasm_mark_saved(): number;
}

const DEFAULT_SAMPLE = `# inzm.zig — Zig Piece Table WASM Editor

Hello from Zig (wasm32-freestanding)!
行配列ではなく「Piece Table（ピーステーブル）」でテキストを管理しています。

下の「Piece Table Inspector」を見ながら編集してみてください:
- 下の「Piece Table Inspector」を見ながら編集してみてください:
- 文字を打つと [A:...] ピースが伸びたり分割されたりします
- Ctrl+D / Cmd+D で次の一致語にカーソル追加（マルチカーソル！）
- Option+↑ / ↓ または Option+クリックでもカーソル追加（Esc で1本に戻す）
- Ctrl+Z / Cmd+Z で全カーソル一括 Undo、Ctrl+Y / Cmd+Shift+Z で Redo
- Ctrl+F / Cmd+F でインクリメンタル検索 + ハイライト
- F2 / Ctrl+G で Piece Table Inspector の表示/非表示を切替
- クリックでカーソル移動、ホイールで画面だけスクロール
`;

const STORAGE_PREFIX = "inzm-zig:";
const IS_MAC = /Mac|iPhone|iPad|iPod/i.test(navigator.platform || navigator.userAgent);

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const bannerEl = document.getElementById("banner")!;
const filenameLabel = document.getElementById("filename-label")!;
const fileInput = document.getElementById("file-input") as HTMLInputElement;
const btnInspector = document.getElementById("btn-inspector")!;
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

class ZigWasmBridge {
  constructor(private readonly exp: ZigWasmExports) {}

  private writeIn(text: string): number {
    const bytes = encoder.encode(text);
    const cap = this.exp.wasm_in_cap();
    const len = Math.min(bytes.length, cap);
    const mem = new Uint8Array(this.exp.memory.buffer, this.exp.wasm_in_ptr(), len);
    mem.set(bytes.subarray(0, len));
    return len;
  }

  private writeFname(name: string): number {
    const bytes = encoder.encode(name);
    const len = Math.min(bytes.length, 255);
    const mem = new Uint8Array(this.exp.memory.buffer, this.exp.wasm_fname_ptr(), len);
    mem.set(bytes.subarray(0, len));
    return len;
  }

  private readOut(len: number): string {
    if (len === 0) return "";
    const slice = new Uint8Array(this.exp.memory.buffer, this.exp.wasm_out_ptr(), len);
    return decoder.decode(slice);
  }

  initEditor(cols: number, rows: number, filename: string, content: string): string {
    const flen = this.writeFname(filename);
    const clen = this.writeIn(content);
    return this.readOut(this.exp.wasm_init(cols, rows, flen, clen));
  }

  loadFile(filename: string, content: string): string {
    const flen = this.writeFname(filename);
    const clen = this.writeIn(content);
    return this.readOut(this.exp.wasm_load_file(flen, clen));
  }

  onData(data: string): string {
    const bytes = encoder.encode(data);
    const cap = this.exp.wasm_in_cap();
    let out = "";
    for (let off = 0; off < bytes.length; off += cap) {
      const chunk = bytes.subarray(off, Math.min(off + cap, bytes.length));
      new Uint8Array(this.exp.memory.buffer, this.exp.wasm_in_ptr(), chunk.length).set(chunk);
      out += this.readOut(this.exp.wasm_on_data(chunk.length));
    }
    return out;
  }

  onResize(cols: number, rows: number): string {
    return this.readOut(this.exp.wasm_on_resize(cols, rows));
  }

  getContent(): string {
    const len = this.exp.wasm_content_len();
    if (len === 0) return "";
    const slice = new Uint8Array(this.exp.memory.buffer, this.exp.wasm_content_ptr(), len);
    return decoder.decode(slice);
  }

  getSelectedText(): string {
    const len = this.exp.wasm_selected_len();
    if (len === 0) return "";
    const slice = new Uint8Array(this.exp.memory.buffer, this.exp.wasm_selected_ptr(), len);
    return decoder.decode(slice);
  }

  deleteSelected(): string {
    return this.readOut(this.exp.wasm_delete_selected());
  }

  shouldQuit(): boolean {
    return this.exp.wasm_should_quit() !== 0;
  }

  takeSaveRequest(): boolean {
    return this.exp.wasm_take_save_request() !== 0;
  }

  markSaved(): string {
    return this.readOut(this.exp.wasm_mark_saved());
  }
}

async function loadWasm(): Promise<ZigWasmBridge> {
  const wasmUrl = `${import.meta.env.BASE_URL}inzm.wasm`;
  const response = await fetch(wasmUrl);
  if (!response.ok) {
    throw new Error(`Failed to fetch ${wasmUrl}: ${response.status}`);
  }
  const bytes = await response.arrayBuffer();
  const { instance } = await WebAssembly.instantiate(bytes, {});
  return new ZigWasmBridge(instance.exports as unknown as ZigWasmExports);
}

async function boot() {
  let currentInputHandledByXterm = false;
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
      cursor: "#ebcb8b",
    },
  });
  const fitAddon = new FitAddon();
  term.loadAddon(fitAddon);
  term.open(terminalContainer);
  fitAddon.fit();

  let wasm: ZigWasmBridge;
  try {
    wasm = await loadWasm();
  } catch (err) {
    showBanner(
      `WASM モジュールのロードに失敗しました: ${err instanceof Error ? err.message : String(err)}`
    );
    return;
  }

  let activeFilename = "sample.txt";
  let exited = false;
  let isImeComposing = false;

  const handleInput = (data: string) => {
    if (exited || !data) return;
    const out = wasm.onData(data);
    term.write(out);

    if (wasm.takeSaveRequest()) {
      const content = wasm.getContent();
      localStorage.setItem(`${STORAGE_PREFIX}${activeFilename}`, content);
      term.write(wasm.markSaved());
    }

    if (wasm.shouldQuit()) {
      exited = true;
      term.writeln("\r\n[inzm.zig exited — click 'Restart' to reopen]");
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
    term.textarea.addEventListener("input", (ev) => {
      const inputEv = ev as InputEvent;
      if (currentInputHandledByXterm || isImeComposing || inputEv.isComposing) {
        return;
      }
      if (inputEv.inputType === "insertText" && inputEv.data) {
        handleInput(inputEv.data);
        if (term.textarea) term.textarea.value = "";
      }
    });
  }

  term.attachCustomKeyEventHandler((ev) => {
    if (isImeComposing || ev.isComposing || ev.keyCode === 229) {
      return true;
    }

    const keyLower = ev.key.toLowerCase();

    // Let printable keys & macOS SKK Ctrl+J reach OS TSM natively without preventDefault().
    if (!ev.ctrlKey && !ev.metaKey && !ev.altKey && ev.key.length === 1) {
      return false;
    }
    if (IS_MAC && ev.ctrlKey && !ev.metaKey && !ev.altKey && keyLower === "j") {
      return false;
    }

    if (ev.type !== "keydown") {
      return true;
    }

    // macOS Command shortcuts
    if (ev.metaKey && !ev.ctrlKey && !ev.altKey) {
      if (keyLower === "s") {
        ev.preventDefault();
        handleInput("\x13");
        return false;
      }
      if (keyLower === "a") {
        ev.preventDefault();
        handleInput("\x1b[97;9u"); // Select all
        return false;
      }
      if (keyLower === "z") {
        ev.preventDefault();
        handleInput(ev.shiftKey ? "\x19" : "\x1a"); // Cmd+Shift+Z -> Redo, Cmd+Z -> Undo
        return false;
      }
      if (keyLower === "f") {
        ev.preventDefault();
        handleInput("\x06"); // Incremental search
        return false;
      }
      if (keyLower === "d") {
        ev.preventDefault();
        handleInput("\x04"); // Add next occurrence (Multi-Cursor)
        return false;
      }
      if (keyLower === "c") {
        const selected = wasm.getSelectedText();
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
        const selected = wasm.getSelectedText();
        if (selected) {
          ev.preventDefault();
          void navigator.clipboard?.writeText(selected);
          term.write(wasm.deleteSelected());
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
        handleInput("\x1b[127;9u");
        return false;
      }
      return true;
    }

    // macOS Option word navigation & multi-cursor (preserve Option+char like Option+¥ -> '\')
    if (ev.altKey && !ev.metaKey && !ev.ctrlKey) {
      if (ev.key === "ArrowUp") {
        ev.preventDefault();
        handleInput("\x1b[1;3A"); // Add cursor above
        return false;
      }
      if (ev.key === "ArrowDown") {
        ev.preventDefault();
        handleInput("\x1b[1;3B"); // Add cursor below
        return false;
      }
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

    if (ev.ctrlKey && !ev.metaKey && !ev.altKey) {
      if (
        ["s", "z", "y", "d", "f", "g", "q", "a", "e", "p", "n", "b", "t"].includes(keyLower)
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
    const frame = wasm.initEditor(term.cols, term.rows, filename, content);
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
    term.write(wasm.onResize(cols, rows));
  });

  terminalContainer.addEventListener("mousedown", () => {
    term.focus();
  });

  window.addEventListener("resize", () => {
    fitAddon.fit();
  });

  btnInspector.addEventListener("click", () => {
    handleInput("\x07"); // Ctrl+G toggles Piece Table Inspector
    term.focus();
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
      term.write(wasm.loadFile(file.name, text));
      term.focus();
    }
    fileInput.value = "";
  });

  btnSave.addEventListener("click", () => {
    const content = wasm.getContent();
    localStorage.setItem(`${STORAGE_PREFIX}${activeFilename}`, content);
    downloadFile(activeFilename, content);
    if (!exited) {
      term.write(wasm.markSaved());
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
      : wasm.getContent();
    startEditor(activeFilename, content);
  });
}

boot();
