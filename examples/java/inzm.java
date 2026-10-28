///usr/bin/env java "$0" "$@" ; exit $?
/*
 * inzm.java - Gosling Emacs & Mocklisp (MLisp) homage in Java
 * Honoring James Gosling's 1981 creation: Gosmacs and its extension language Mocklisp.
 * Run directly with: java inzm.java [filename]
 */

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.regex.*;

public class inzm {

    // =========================================================================
    // 0. 文字幅判定 & DSR EAW 自動検知
    // =========================================================================
    static boolean isEaw = true;

    static int getCharWidth(int code) {
        // 1. 確定全角 (Wide / Fullwidth)
        if ((code >= 0x1100 && code <= 0x115F) ||
            (code >= 0x2E80 && code <= 0xA4CF) ||
            (code >= 0xAC00 && code <= 0xD7A3) ||
            (code >= 0xF900 && code <= 0xFAFF) ||
            (code >= 0xFE10 && code <= 0xFE19) ||
            (code >= 0xFE30 && code <= 0xFE6F) ||
            (code >= 0xFF01 && code <= 0xFF60) ||
            (code >= 0xFFE0 && code <= 0xFFE6)) {
            return 2;
        }

        // 2. 東アジア曖昧幅 (Ambiguous Width: ギリシャ、キリル、記号など)
        if ((code >= 0x0370 && code <= 0x03FF) ||
            (code >= 0x0400 && code <= 0x04FF) ||
            (code >= 0x2010 && code <= 0x205E) ||
            (code >= 0x2100 && code <= 0x214F) ||
            (code >= 0x2190 && code <= 0x21FF) ||
            (code >= 0x2200 && code <= 0x22FF) ||
            (code >= 0x25A0 && code <= 0x25FF) ||
            (code >= 0x2600 && code <= 0x26FF)) {
            return isEaw ? 2 : 1;
        }

        return 1;
    }

    static int getStringWidth(String s) {
        int w = 0;
        int i = 0;
        while (i < s.length()) {
            int cp = s.codePointAt(i);
            w += getCharWidth(cp);
            i += Character.charCount(cp);
        }
        return w;
    }

    static String truncateToWidth(String s, int maxW) {
        StringBuilder sb = new StringBuilder();
        int curW = 0;
        int i = 0;
        while (i < s.length()) {
            int cp = s.codePointAt(i);
            int w = getCharWidth(cp);
            if (curW + w > maxW) break;
            sb.appendCodePoint(cp);
            curW += w;
            i += Character.charCount(cp);
        }
        return sb.toString();
    }

    // DSRプローブによる EAW 自動検知
    static boolean probeEaw() {
        try {
            System.out.print("\033[1;1H\033[2Kα\033[6n");
            System.out.flush();

            StringBuilder resp = new StringBuilder();
            long start = System.currentTimeMillis();
            while (System.currentTimeMillis() - start < 100) {
                if (System.in.available() > 0) {
                    int c = System.in.read();
                    if (c == -1) break;
                    resp.append((char) c);
                    if (c == 'R') break;
                } else {
                    Thread.sleep(5);
                }
            }
            System.out.print("\033[1;1H\033[2K");
            System.out.flush();

            Matcher m = Pattern.compile("\\[\\d+;(\\d+)R").matcher(resp.toString());
            if (m.find()) {
                int col = Integer.parseInt(m.group(1));
                return col == 3;
            }
        } catch (Exception ignored) {}
        return true;
    }

    // =========================================================================
    // 1. Mocklisp (MLisp) 軽量S式パーサ & 実行エンジン
    // =========================================================================
    static class MLSymbol {
        public final String name;
        public MLSymbol(String name) { this.name = name; }
        @Override public String toString() { return name; }
        @Override public boolean equals(Object o) {
            return (o instanceof MLSymbol s) && name.equals(s.name);
        }
        @Override public int hashCode() { return name.hashCode(); }
    }

    static class MLParser {
        private final String src;
        private int pos = 0;

        public MLParser(String src) { this.src = src; }

        public List<Object> parseAll() {
            List<Object> exprs = new ArrayList<>();
            while (true) {
                skipWhitespaceAndComments();
                if (pos >= src.length()) break;
                exprs.add(parseExpr());
            }
            return exprs;
        }

        private void skipWhitespaceAndComments() {
            while (pos < src.length()) {
                char c = src.charAt(pos);
                if (Character.isWhitespace(c)) {
                    pos++;
                } else if (c == ';') { // 行コメント
                    while (pos < src.length() && src.charAt(pos) != '\n') pos++;
                } else {
                    break;
                }
            }
        }

        public Object parseExpr() {
            skipWhitespaceAndComments();
            if (pos >= src.length()) return null;

            char c = src.charAt(pos);
            if (c == '(') {
                pos++;
                List<Object> list = new ArrayList<>();
                while (true) {
                    skipWhitespaceAndComments();
                    if (pos >= src.length()) break;
                    if (src.charAt(pos) == ')') {
                        pos++;
                        break;
                    }
                    list.add(parseExpr());
                }
                return list;
            } else if (c == '"') {
                return parseString();
            } else {
                return parseAtom();
            }
        }

        private String parseString() {
            pos++; // skip "
            StringBuilder sb = new StringBuilder();
            while (pos < src.length()) {
                char c = src.charAt(pos++);
                if (c == '"') break;
                if (c == '\\' && pos < src.length()) {
                    char esc = src.charAt(pos++);
                    switch (esc) {
                        case 'n' -> sb.append('\n');
                        case 't' -> sb.append('\t');
                        case 'r' -> sb.append('\r');
                        case '"' -> sb.append('"');
                        case '\\' -> sb.append('\\');
                        default -> sb.append(esc);
                    }
                } else {
                    sb.append(c);
                }
            }
            return sb.toString();
        }

        private Object parseAtom() {
            int start = pos;
            while (pos < src.length()) {
                char c = src.charAt(pos);
                if (Character.isWhitespace(c) || c == '(' || c == ')' || c == '"' || c == ';') break;
                pos++;
            }
            String tok = src.substring(start, pos);
            try {
                return Long.parseLong(tok);
            } catch (NumberFormatException e) {
                return new MLSymbol(tok);
            }
        }
    }

    static class MLEvaluator {
        private final Map<String, Object> globals = new HashMap<>();

        public Object eval(Object expr, Editor ed) {
            if (expr == null) return null;
            if (expr instanceof Long || expr instanceof String) return expr;
            if (expr instanceof MLSymbol sym) {
                return globals.getOrDefault(sym.name, 0L);
            }
            if (expr instanceof List<?> rawList) {
                if (rawList.isEmpty()) return Collections.emptyList();
                @SuppressWarnings("unchecked")
                List<Object> list = (List<Object>) rawList;
                Object head = list.get(0);
                String fnName = (head instanceof MLSymbol s) ? s.name : String.valueOf(head);
                List<Object> args = list.subList(1, list.size());

                return callPrimitive(fnName, args, ed);
            }
            return null;
        }

        private Object callPrimitive(String fn, List<Object> args, Editor ed) {
            switch (fn) {
                // --- 制御構文 ---
                case "progn" -> {
                    Object last = null;
                    for (Object arg : args) {
                        last = eval(arg, ed);
                    }
                    return last;
                }
                case "setq" -> {
                    if (args.size() >= 2 && args.get(0) instanceof MLSymbol sym) {
                        Object val = eval(args.get(1), ed);
                        globals.put(sym.name, val);
                        return val;
                    }
                    return 0L;
                }
                case "if" -> {
                    if (!args.isEmpty()) {
                        Object condVal = eval(args.get(0), ed);
                        boolean truthy = isTruthy(condVal);
                        if (truthy && args.size() > 1) {
                            return eval(args.get(1), ed);
                        } else if (!truthy && args.size() > 2) {
                            return eval(args.get(2), ed);
                        }
                    }
                    return 0L;
                }
                case "message" -> {
                    if (!args.isEmpty()) {
                        Object msg = eval(args.get(0), ed);
                        ed.statusMessage = String.valueOf(msg);
                        return msg;
                    }
                    return "";
                }

                // --- Gosmacs / Mocklisp エディタ基本プリミティブ ---
                case "insert-string" -> {
                    if (!args.isEmpty()) {
                        Object val = eval(args.get(0), ed);
                        String str = (val != null) ? val.toString() : "";
                        ed.insertString(str);
                    }
                    return 0L;
                }
                case "insert-character" -> {
                    if (!args.isEmpty()) {
                        Object val = eval(args.get(0), ed);
                        if (val instanceof Long l) {
                            ed.insertString(Character.toString((int) l.longValue()));
                        }
                    }
                    return 0L;
                }
                case "beginning-of-line" -> {
                    ed.cursorX = 0;
                    return 0L;
                }
                case "end-of-line" -> {
                    ed.cursorX = ed.currentLine().length();
                    return 0L;
                }
                case "next-line" -> {
                    ed.moveCursor(0, 1);
                    return 0L;
                }
                case "previous-line" -> {
                    ed.moveCursor(0, -1);
                    return 0L;
                }
                case "forward-character" -> {
                    ed.moveCursor(1, 0);
                    return 0L;
                }
                case "backward-character" -> {
                    ed.moveCursor(-1, 0);
                    return 0L;
                }
                case "delete-previous-character" -> {
                    ed.deleteBackward();
                    return 0L;
                }
                case "delete-next-character" -> {
                    ed.deleteForward();
                    return 0L;
                }
                case "kill-to-end-of-line" -> {
                    ed.killToEndOfLine();
                    return 0L;
                }
                case "write-current-file", "save-file" -> {
                    ed.saveFile();
                    return 0L;
                }
                case "exit-emacs" -> {
                    ed.running = false;
                    return 0L;
                }
                case "dot" -> {
                    // バッファ先頭からのオフセット (簡易版)
                    return (long) (ed.cursorY * 1000 + ed.cursorX);
                }

                // --- 算術演算 ---
                case "+" -> {
                    long sum = 0;
                    for (Object a : args) {
                        Object v = eval(a, ed);
                        if (v instanceof Long l) sum += l;
                    }
                    return sum;
                }
                case "-" -> {
                    if (args.isEmpty()) return 0L;
                    long res = (Long) eval(args.get(0), ed);
                    for (int i = 1; i < args.size(); i++) {
                        res -= (Long) eval(args.get(i), ed);
                    }
                    return res;
                }
                default -> {
                    ed.statusMessage = "Unknown Mocklisp fn: " + fn;
                    return 0L;
                }
            }
        }

        private boolean isTruthy(Object v) {
            if (v == null) return false;
            if (v instanceof Long l) return l != 0;
            if (v instanceof String s) return !s.isEmpty();
            if (v instanceof List<?> l) return !l.isEmpty();
            return true;
        }
    }

    // =========================================================================
    // 2. Editor 本体
    // =========================================================================
    static class Editor {
        String filename;
        List<String> lines = new ArrayList<>(List.of(""));
        int cursorX = 0;
        int cursorY = 0;
        int rowOffset = 0;
        boolean isModified = false;
        String statusMessage = "";
        boolean running = true;
        boolean prefixCtrlX = false;

        final MLEvaluator mlisp = new MLEvaluator();

        Editor(String filename) {
            this.filename = (filename != null && !filename.isBlank()) ? filename : "untitled.txt";
            loadFile();
            loadInitScript();
        }

        void loadFile() {
            try {
                Path path = Path.of(filename);
                if (Files.exists(path)) {
                    String content = Files.readString(path, StandardCharsets.UTF_8);
                    String norm = content.replaceFirst("\\r?\\n$", "");
                    String[] split = norm.replace("\r", "").split("\n", -1);
                    lines = new ArrayList<>(Arrays.asList(split));
                    if (lines.isEmpty()) lines.add("");
                }
            } catch (Exception e) {
                statusMessage = "Load error: " + e.getMessage();
            }
        }

        void loadInitScript() {
            Path initPath = Path.of("./init.ml");
            if (Files.exists(initPath)) {
                try {
                    String code = Files.readString(initPath, StandardCharsets.UTF_8);
                    MLParser parser = new MLParser(code);
                    for (Object expr : parser.parseAll()) {
                        mlisp.eval(expr, this);
                    }
                    statusMessage = "Loaded init.ml (Mocklisp)";
                } catch (Exception e) {
                    statusMessage = "init.ml error: " + e.getMessage();
                }
            }
        }

        String currentLine() {
            return (cursorY < lines.size()) ? lines.get(cursorY) : "";
        }

        void insertString(String s) {
            String line = currentLine();
            String before = line.substring(0, Math.min(cursorX, line.length()));
            String after = line.substring(Math.min(cursorX, line.length()));
            lines.set(cursorY, before + s + after);
            cursorX += s.length();
            isModified = true;
        }

        void insertNewline() {
            String line = currentLine();
            String before = line.substring(0, Math.min(cursorX, line.length()));
            String after = line.substring(Math.min(cursorX, line.length()));
            lines.set(cursorY, before);
            lines.add(cursorY + 1, after);
            cursorY++;
            cursorX = 0;
            isModified = true;
        }

        void deleteBackward() {
            if (cursorX > 0) {
                String line = currentLine();
                String before = line.substring(0, cursorX - 1);
                String after = line.substring(cursorX);
                lines.set(cursorY, before + after);
                cursorX--;
                isModified = true;
            } else if (cursorY > 0) {
                int prevLen = lines.get(cursorY - 1).length();
                lines.set(cursorY - 1, lines.get(cursorY - 1) + currentLine());
                lines.remove(cursorY);
                cursorY--;
                cursorX = prevLen;
                isModified = true;
            }
        }

        void deleteForward() {
            String line = currentLine();
            if (cursorX < line.length()) {
                String before = line.substring(0, cursorX);
                String after = line.substring(cursorX + 1);
                lines.set(cursorY, before + after);
                isModified = true;
            } else if (cursorY < lines.size() - 1) {
                lines.set(cursorY, line + lines.get(cursorY + 1));
                lines.remove(cursorY + 1);
                isModified = true;
            }
        }

        void killToEndOfLine() {
            String line = currentLine();
            if (cursorX < line.length()) {
                lines.set(cursorY, line.substring(0, cursorX));
            } else if (cursorY < lines.size() - 1) {
                lines.set(cursorY, line + lines.get(cursorY + 1));
                lines.remove(cursorY + 1);
            }
            isModified = true;
        }

        void moveCursor(int dx, int dy) {
            int newY = Math.max(0, Math.min(lines.size() - 1, cursorY + dy));
            cursorY = newY;
            String line = currentLine();
            cursorX = Math.min(cursorX, line.length());

            if (dx != 0) {
                cursorX = Math.max(0, Math.min(line.length(), cursorX + dx));
            }
        }

        void saveFile() {
            try {
                String content = String.join("\n", lines) + "\n";
                Files.writeString(Path.of(filename), content, StandardCharsets.UTF_8);
                isModified = false;
                statusMessage = "Wrote " + filename;
            } catch (Exception e) {
                statusMessage = "Save error: " + e.getMessage();
            }
        }

        void evalPrompt() {
            String code = promptInput("Eval (MLisp): ");
            if (code == null || code.isBlank()) return;
            try {
                MLParser parser = new MLParser(code);
                Object last = null;
                for (Object expr : parser.parseAll()) {
                    last = mlisp.eval(expr, this);
                }
                statusMessage = "=> " + last;
            } catch (Exception e) {
                statusMessage = "MLisp error: " + e.getMessage();
            }
        }

        String promptInput(String promptText) {
            int rows = getTerminalRows();
            StringBuilder buf = new StringBuilder();
            while (true) {
                System.out.printf("\033[%d;1H\033[7m %s%s \033[0m\033[K", rows, promptText, buf);
                System.out.flush();

                int c = readRawByte();
                if (c == '\r' || c == '\n') {
                    return buf.toString();
                } else if (c == 0x07 || c == 0x1B || c == 0x03) { // C-g, Esc, C-c
                    statusMessage = "Quit";
                    return null;
                } else if (c == 0x7F || c == 0x08) { // Backspace
                    if (buf.length() > 0) buf.deleteCharAt(buf.length() - 1);
                } else if (c >= 0x20) {
                    buf.append((char) c);
                }
            }
        }

        void setTitle(String title) {
            System.out.printf("\033]0;%s\007", title);
        }

        int getTerminalCols() {
            try {
                String s = executeCommand("tput cols");
                return Integer.parseInt(s.trim());
            } catch (Exception e) { return 80; }
        }

        int getTerminalRows() {
            try {
                String s = executeCommand("tput lines");
                return Integer.parseInt(s.trim());
            } catch (Exception e) { return 24; }
        }

        void render() {
            int cols = getTerminalCols();
            int rows = getTerminalRows();
            int screenRows = Math.max(1, rows - 1);

            if (cursorY < rowOffset) rowOffset = cursorY;
            if (cursorY >= rowOffset + screenRows) rowOffset = cursorY - screenRows + 1;

            setTitle("inzm (Gosmacs) - " + filename + (isModified ? "*" : ""));

            StringBuilder out = new StringBuilder();
            out.append("\033[?25l"); // カーソル隠す

            // 1. 本文テキストエリア
            for (int i = 0; i < screenRows; i++) {
                int fileRow = rowOffset + i;
                out.append(String.format("\033[%d;1H", i + 1));

                if (fileRow < lines.size()) {
                    String lineNum = String.format("%3d ", fileRow + 1);
                    out.append("\033[90m").append(lineNum).append("\033[0m");
                    out.append(lines.get(fileRow));
                    out.append("\033[K");
                } else {
                    out.append("\033[90m  ~ \033[0m\033[K");
                }
            }

            // 2. ステータスライン (最下行: Emacs / Gosmacs スタイル)
            out.append(String.format("\033[%d;1H\033[7m", rows));
            String modMark = isModified ? "**" : "--";
            String pfxMark = prefixCtrlX ? " C-x-" : "";
            String eawLabel = isEaw ? "EAW" : "Non-EAW";
            String leftStatus = String.format("-%s-  [Gosmacs:MLisp] %s  (%s)%s  L%d/C%d",
                    modMark, filename, eawLabel, pfxMark, cursorY + 1, cursorX + 1);
            String rightStatus = (!statusMessage.isEmpty())
                    ? statusMessage + " | M-:: MLisp "
                    : "M-:: MLisp | C-x C-s: Save | C-x C-c: Quit ";

            int maxW = cols - 1;
            int pad = Math.max(0, maxW - getStringWidth(leftStatus) - getStringWidth(rightStatus));
            String fullBar = leftStatus + " ".repeat(pad) + rightStatus;
            out.append(truncateToWidth(fullBar, maxW)).append("\033[0m\033[K");

            // 3. カーソル位置の設定
            int screenY = cursorY - rowOffset + 1;
            String line = currentLine();
            String before = line.substring(0, Math.min(cursorX, line.length()));
            int visualX = getStringWidth(before);
            int screenX = visualX + 5; // 行番号幅 (4) + 1

            out.append(String.format("\033[%d;%dH\033[?25h", screenY, screenX));

            System.out.print(out);
            System.out.flush();
        }

        // =====================================================================
        // 3. メインループ & 入力処理
        // =====================================================================
        void run() {
            setRawMode(true);
            System.out.print("\033[?1049h\033[2J\033[H"); // 代替画面
            System.out.flush();

            isEaw = probeEaw();
            render();

            try {
                while (running) {
                    int c = readRawByte();
                    if (c == -1) break;

                    if (!statusMessage.startsWith("=>") && !statusMessage.startsWith("MLisp error") && !statusMessage.startsWith("Quit")) {
                        statusMessage = "";
                    }

                    handleKey(c);
                    if (running) render();
                }
            } finally {
                setTitle("");
                System.out.print("\033[?1049l\033[?25h");
                System.out.flush();
                setRawMode(false);
            }
        }

        void handleKey(int c) {
            // C-x プレフィックス処理
            if (prefixCtrlX) {
                prefixCtrlX = false;
                if (c == 0x13) { // C-s : 保存
                    saveFile();
                } else if (c == 0x03) { // C-c : 終了
                    running = false;
                } else {
                    statusMessage = String.format("C-x %c is undefined", (char)c);
                }
                return;
            }

            switch (c) {
                case 0x18 -> { // C-x
                    prefixCtrlX = true;
                }
                case 0x10 -> moveCursor(0, -1); // C-p (Previous line)
                case 0x0E -> moveCursor(0, 1);  // C-n (Next line)
                case 0x06 -> moveCursor(1, 0);  // C-f (Forward char)
                case 0x02 -> moveCursor(-1, 0); // C-b (Backward char)
                case 0x01 -> cursorX = 0;       // C-a (Beginning of line)
                case 0x05 -> cursorX = currentLine().length(); // C-e (End of line)
                case 0x04 -> deleteForward();   // C-d (Delete char)
                case 0x0B -> killToEndOfLine(); // C-k (Kill line)
                case 0x07 -> {                  // C-g (Cancel)
                    prefixCtrlX = false;
                    statusMessage = "Quit";
                }
                case '\r', '\n' -> insertNewline();
                case 0x7F, 0x08 -> deleteBackward();
                case 0x1B -> handleEscapeSequence(); // Esc or Meta
                default -> {
                    if (c >= 0x20) {
                        insertString(Character.toString((char) c));
                    }
                }
            }
        }

        void handleEscapeSequence() {
            try {
                if (System.in.available() == 0) {
                    // 単独の Esc キー
                    return;
                }
                int c2 = System.in.read();
                if (c2 == ':') {
                    // M-: (Eval Mocklisp expression!)
                    evalPrompt();
                } else if (c2 == 'v') {
                    // M-v (PageUp)
                    moveCursor(0, -(getTerminalRows() - 1));
                } else if (c2 == '[') {
                    // 矢印キーなど
                    int c3 = System.in.read();
                    switch (c3) {
                        case 'A' -> moveCursor(0, -1); // Up
                        case 'B' -> moveCursor(0, 1);  // Down
                        case 'C' -> moveCursor(1, 0);  // Right
                        case 'D' -> moveCursor(-1, 0); // Left
                        case '5' -> moveCursor(0, -(getTerminalRows() - 1)); // PageUp
                        case '6' -> moveCursor(0, getTerminalRows() - 1);  // PageDown
                        case 'H' -> cursorX = 0; // Home
                        case 'F' -> cursorX = currentLine().length(); // End
                    }
                }
            } catch (Exception ignored) {}
        }
    }

    // =========================================================================
    // 4. ターミナル生モード制御ヘルパー
    // =========================================================================
    static void setRawMode(boolean enable) {
        try {
            if (enable) {
                executeCommand("stty -icanon -echo");
            } else {
                executeCommand("stty sane");
            }
        } catch (Exception ignored) {}
    }

    static int readRawByte() {
        try {
            return System.in.read();
        } catch (Exception e) {
            return -1;
        }
    }

    static String executeCommand(String cmd) throws Exception {
        Process p = new ProcessBuilder("sh", "-c", cmd).start();
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(p.getInputStream()))) {
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = reader.readLine()) != null) {
                sb.append(line).append("\n");
            }
            p.waitFor();
            return sb.toString().trim();
        }
    }

    // =========================================================================
    // 5. エントリポイント
    // =========================================================================
    public static void main(String[] args) {
        String fname = (args.length > 0) ? args[0] : "untitled.txt";
        Editor ed = new Editor(fname);
        ed.run();
    }
}
