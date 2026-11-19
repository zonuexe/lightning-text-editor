import "@xterm/xterm/css/xterm.css";
import "./style.css";

import { FitAddon } from "@xterm/addon-fit";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import { Terminal } from "@xterm/xterm";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

interface RenderPayload {
  frame: string;
  title: string;
}

interface InitPayload extends RenderPayload {
  init_seq: string;
}

const IS_MAC = navigator.platform.toUpperCase().includes("MAC");

const terminalContainer = document.getElementById("terminal");
if (!terminalContainer) {
  throw new Error("Missing #terminal container");
}

const term = new Terminal({
  fontFamily:
    'ui-monospace, "SF Mono", Menlo, Monaco, Consolas, "Hiragino Kaku Gothic ProN", "Hiragino Sans", monospace',
  fontSize: 15,
  cursorBlink: true,
  cursorStyle: "bar",
  allowProposedApi: true,
  scrollback: 0,
  theme: {
    background: "#1e1e2e",
    foreground: "#cdd6f4",
    cursor: "#f5e0dc",
    selectionBackground: "#45475a",
  },
});

const fitAddon = new FitAddon();
const unicode11Addon = new Unicode11Addon();
term.loadAddon(fitAddon);
term.loadAddon(unicode11Addon);
term.unicode.activeVersion = "11";

// State for SKK / macOS direct-kana input fallback (docs/browser-wasm-runtime.md)
let isImeComposing = false;
let currentInputHandledByXterm = false;

// Register capture listener BEFORE term.open so it runs ahead of xterm's internal input handler
terminalContainer.addEventListener(
  "input",
  () => {
    currentInputHandledByXterm = false;
  },
  true,
);

term.open(terminalContainer);
fitAddon.fit();

function applyPayload(payload: RenderPayload): void {
  document.title = payload.title;
  term.write(payload.frame);
}

// Serialize input/resize IPC calls so keystrokes arrive in strict order
let ipcChain: Promise<void> = Promise.resolve();

function enqueueData(data: string): void {
  if (!data) return;
  ipcChain = ipcChain
    .then(async () => {
      const payload = await invoke<RenderPayload>("on_data", { data });
      applyPayload(payload);
    })
    .catch((err) => {
      console.error("on_data error:", err);
    });
}

function enqueueCommand(cmd: string, args?: Record<string, unknown>): void {
  ipcChain = ipcChain
    .then(async () => {
      const payload = await invoke<RenderPayload>(cmd, args);
      applyPayload(payload);
      term.focus();
    })
    .catch((err) => {
      console.error(`${cmd} error:`, err);
    });
}

term.onData((data) => {
  currentInputHandledByXterm = true;
  enqueueData(data);
});

const textarea = term.textarea;
if (textarea) {
  textarea.addEventListener("compositionstart", () => {
    isImeComposing = true;
  });
  textarea.addEventListener("compositionend", () => {
    setTimeout(() => {
      isImeComposing = false;
    }, 0);
  });
  textarea.addEventListener("input", (ev) => {
    const inputEv = ev as InputEvent;
    if (
      !currentInputHandledByXterm &&
      !isImeComposing &&
      !inputEv.isComposing &&
      inputEv.inputType === "insertText" &&
      inputEv.data
    ) {
      enqueueData(inputEv.data);
      textarea.value = "";
    }
  });
}

async function handleCopy(): Promise<void> {
  const text = await invoke<string>("get_selected_text");
  if (text) {
    await navigator.clipboard.writeText(text);
  }
}

async function handleCut(): Promise<void> {
  const [text, payload] = await invoke<[string, RenderPayload]>("cut_selection");
  if (text) {
    await navigator.clipboard.writeText(text);
  }
  applyPayload(payload);
}

term.attachCustomKeyEventHandler((ev: KeyboardEvent): boolean => {
  // 1. Let active IME composition pass cleanly through textarea
  if (isImeComposing || ev.isComposing || ev.keyCode === 229) {
    return true;
  }

  // 2. Single printable character with no modifiers: return false (no preventDefault)
  // so macSKK/AquaSKK kana mode receives keydown and dispatches insertText.
  if (!ev.ctrlKey && !ev.metaKey && !ev.altKey && ev.key.length === 1) {
    return false;
  }

  const keyLower = ev.key.toLowerCase();

  // 3. Preserve Ctrl+J on macOS for SKK kana conversion
  if (IS_MAC && ev.ctrlKey && !ev.metaKey && !ev.altKey && keyLower === "j") {
    return false;
  }

  if (ev.type !== "keydown") {
    return true;
  }

  // 4. Copy / Cut using browser user gesture for clipboard access
  const primary = IS_MAC ? ev.metaKey : ev.ctrlKey;
  if (primary && !ev.altKey && !ev.shiftKey) {
    if (keyLower === "c") {
      ev.preventDefault();
      void handleCopy();
      return false;
    }
    if (keyLower === "x") {
      ev.preventDefault();
      void handleCut();
      return false;
    }
  }

  // 5. macOS Cmd / Option cursor & deletion shortcuts
  if (IS_MAC && ev.metaKey && !ev.ctrlKey && !ev.altKey) {
    if (ev.key === "ArrowLeft") {
      ev.preventDefault();
      enqueueData(ev.shiftKey ? "\x1b[1;2H" : "\x1b[H");
      return false;
    }
    if (ev.key === "ArrowRight") {
      ev.preventDefault();
      enqueueData(ev.shiftKey ? "\x1b[1;2F" : "\x1b[F");
      return false;
    }
    if (ev.key === "ArrowUp") {
      ev.preventDefault();
      enqueueData(ev.shiftKey ? "\x1b[1;10A" : "\x1b[1;9A");
      return false;
    }
    if (ev.key === "ArrowDown") {
      ev.preventDefault();
      enqueueData(ev.shiftKey ? "\x1b[1;10B" : "\x1b[1;9B");
      return false;
    }
    if (ev.key === "Backspace") {
      ev.preventDefault();
      enqueueData("\x15");
      return false;
    }
  }

  if (IS_MAC && ev.altKey && !ev.metaKey && !ev.ctrlKey) {
    if (ev.key === "ArrowLeft") {
      ev.preventDefault();
      enqueueData(ev.shiftKey ? "\x1b[1;4D" : "\x1b[1;3D");
      return false;
    }
    if (ev.key === "ArrowRight") {
      ev.preventDefault();
      enqueueData(ev.shiftKey ? "\x1b[1;4C" : "\x1b[1;3C");
      return false;
    }
    if (ev.key === "Backspace") {
      ev.preventDefault();
      enqueueData("\x1b\x7f");
      return false;
    }
    if (ev.key === "Delete") {
      ev.preventDefault();
      enqueueData("\x1b[3;3~");
      return false;
    }
    // Option+<char> (e.g., JIS Option+¥ -> \) falls through cleanly
  }

  return true;
});

window.addEventListener("resize", () => {
  fitAddon.fit();
  enqueueCommand("on_resize", { cols: term.cols, rows: term.rows });
});

// Wire toolbar buttons
document.getElementById("btn-new")?.addEventListener("click", () => {
  enqueueCommand("new_tab");
});
document.getElementById("btn-open")?.addEventListener("click", () => {
  void invoke("open_file_dialog");
  term.focus();
});
document.getElementById("btn-save")?.addEventListener("click", () => {
  void invoke("save_file");
  term.focus();
});
document.getElementById("btn-save-as")?.addEventListener("click", () => {
  void invoke("save_file_as");
  term.focus();
});
document.getElementById("btn-undo")?.addEventListener("click", () => {
  enqueueData("\x1a");
  term.focus();
});
document.getElementById("btn-redo")?.addEventListener("click", () => {
  enqueueData("\x19");
  term.focus();
});
document.getElementById("btn-find")?.addEventListener("click", () => {
  enqueueData("\x06");
  term.focus();
});
document.getElementById("btn-eaw")?.addEventListener("click", () => {
  enqueueCommand("toggle_eaw");
});

async function bootstrap(): Promise<void> {
  await listen<RenderPayload>("editor-sync", (event) => {
    applyPayload(event.payload);
  });
  await listen("menu-copy", () => {
    void handleCopy();
  });
  await listen("menu-cut", () => {
    void handleCut();
  });

  const init = await invoke<InitPayload>("init_editor", {
    cols: term.cols,
    rows: term.rows,
  });
  term.write(init.init_seq);
  applyPayload(init);
  term.focus();
}

void bootstrap();
