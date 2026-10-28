package inzm;

/*
 * Inzm.java - Gosling Emacs & Mocklisp (MLisp) with RSyntaxTextArea syntax highlighting in Java
 * Honoring James Gosling's 1981 creation: Gosmacs and its extension language Mocklisp.
 */

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.regex.*;
import javax.swing.text.Segment;

import org.fife.ui.rsyntaxtextarea.SyntaxConstants;
import org.fife.ui.rsyntaxtextarea.Token;
import org.fife.ui.rsyntaxtextarea.TokenMaker;
import org.fife.ui.rsyntaxtextarea.TokenMakerFactory;
import org.fife.ui.rsyntaxtextarea.TokenTypes;

public class Inzm {

    // =========================================================================
    // 0. 文字幅判定 & DSR EAW 自動検知
    // =========================================================================
    static boolean isEaw = true;

    static int getCharWidth(int code) {
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
    // 1. RSyntaxTextArea シンタックスハイライター統合
    // =========================================================================
    static class SyntaxColorizer {
        private final TokenMaker tokenMaker;
        private final String langName;

        public SyntaxColorizer(String filename) {
            String lower = filename.toLowerCase();
            String base = Path.of(filename).getFileName().toString().toLowerCase();
            String style = null;
            String name = "Text";

            if (lower.endsWith(".java")) {
                style = SyntaxConstants.SYNTAX_STYLE_JAVA;
                name = "Java";
            } else if (lower.endsWith(".php")) {
                style = SyntaxConstants.SYNTAX_STYLE_PHP;
                name = "PHP";
            } else if (lower.endsWith(".sh") || lower.endsWith(".bash") || lower.endsWith(".zsh")) {
                style = SyntaxConstants.SYNTAX_STYLE_UNIX_SHELL;
                name = "Shell";
            } else if (lower.endsWith(".go")) {
                style = SyntaxConstants.SYNTAX_STYLE_GO;
                name = "Go";
            } else if (lower.endsWith(".rs")) {
                style = SyntaxConstants.SYNTAX_STYLE_RUST;
                name = "Rust";
            } else if (lower.endsWith(".ts") || lower.endsWith(".tsx")) {
                style = SyntaxConstants.SYNTAX_STYLE_TYPESCRIPT;
                name = "TypeScript";
            } else if (lower.endsWith(".js") || lower.endsWith(".jsx") || lower.endsWith(".mjs")) {
                style = SyntaxConstants.SYNTAX_STYLE_JAVASCRIPT;
                name = "JavaScript";
            } else if (lower.endsWith(".py")) {
                style = SyntaxConstants.SYNTAX_STYLE_PYTHON;
                name = "Python";
            } else if (lower.endsWith(".rb")) {
                style = SyntaxConstants.SYNTAX_STYLE_RUBY;
                name = "Ruby";
            } else if (lower.endsWith(".c") || lower.endsWith(".h")) {
                style = SyntaxConstants.SYNTAX_STYLE_C;
                name = "C";
            } else if (lower.endsWith(".cpp") || lower.endsWith(".hpp") || lower.endsWith(".cc") || lower.endsWith(".cxx")) {
                style = SyntaxConstants.SYNTAX_STYLE_CPLUSPLUS;
                name = "C++";
            } else if (lower.endsWith(".json")) {
                style = SyntaxConstants.SYNTAX_STYLE_JSON;
                name = "JSON";
            } else if (lower.endsWith(".md") || lower.endsWith(".markdown")) {
                style = SyntaxConstants.SYNTAX_STYLE_MARKDOWN;
                name = "Markdown";
            } else if (lower.endsWith(".yml") || lower.endsWith(".yaml")) {
                style = SyntaxConstants.SYNTAX_STYLE_YAML;
                name = "YAML";
            } else if (lower.endsWith(".html") || lower.endsWith(".htm")) {
                style = SyntaxConstants.SYNTAX_STYLE_HTML;
                name = "HTML";
            } else if (lower.endsWith(".xml")) {
                style = SyntaxConstants.SYNTAX_STYLE_XML;
                name = "XML";
            } else if (lower.endsWith(".sql")) {
                style = SyntaxConstants.SYNTAX_STYLE_SQL;
                name = "SQL";
            } else if (lower.endsWith(".properties") || lower.endsWith(".ini")) {
                style = SyntaxConstants.SYNTAX_STYLE_PROPERTIES_FILE;
                name = "Properties";
            } else if (base.equals("dockerfile")) {
                style = SyntaxConstants.SYNTAX_STYLE_DOCKERFILE;
                name = "Dockerfile";
            } else if (base.equals("makefile")) {
                style = SyntaxConstants.SYNTAX_STYLE_MAKEFILE;
                name = "Makefile";
            } else if (lower.endsWith(".ml") || lower.endsWith(".lisp") || lower.endsWith(".cl") || lower.endsWith(".el")) {
                style = SyntaxConstants.SYNTAX_STYLE_LISP;
                name = "Lisp";
            }

            if (style != null) {
                this.tokenMaker = TokenMakerFactory.getDefaultInstance().getTokenMaker(style);
                this.langName = name;
            } else {
                this.tokenMaker = null;
                this.langName = "Text";
            }
        }

        public String getLangName() { return langName; }

        public String highlightLine(String line) {
            if (tokenMaker == null || line.isEmpty()) {
                return line;
            }

            char[] chars = line.toCharArray();
            Segment segment = new Segment(chars, 0, chars.length);
            Token token = tokenMaker.getTokenList(segment, TokenTypes.NULL, 0);

            StringBuilder sb = new StringBuilder();
            while (token != null && token.isPaintable()) {
                String color = tokenToAnsi(token.getType());
                sb.append(color).append(token.getLexeme()).append("\033[0m");
                token = token.getNextToken();
            }
            return sb.toString();
        }

        private String tokenToAnsi(int tokenType) {
            switch (tokenType) {
                // キーワード
                case TokenTypes.RESERVED_WORD, TokenTypes.RESERVED_WORD_2 -> {
                    return "\033[1;36m"; // 太字シアン
                }
                // データ型
                case TokenTypes.DATA_TYPE -> {
                    return "\033[34m"; // 青
                }
                // コメント
                case TokenTypes.COMMENT_EOL, TokenTypes.COMMENT_MULTILINE,
                     TokenTypes.COMMENT_DOCUMENTATION, TokenTypes.COMMENT_KEYWORD -> {
                    return "\033[90m"; // グレー
                }
                // 文字列
                case TokenTypes.LITERAL_STRING_DOUBLE_QUOTE, TokenTypes.LITERAL_CHAR -> {
                    return "\033[32m"; // 緑
                }
                // 数値
                case TokenTypes.LITERAL_NUMBER_DECIMAL_INT, TokenTypes.LITERAL_NUMBER_FLOAT,
                     TokenTypes.LITERAL_NUMBER_HEXADECIMAL -> {
                    return "\033[35m"; // マゼンタ / 紫
                }
                // 関数 / メソッド
                case TokenTypes.FUNCTION -> {
                    return "\033[33m"; // 黄色
                }
                // 演算子
                case TokenTypes.OPERATOR -> {
                    return "\033[37m"; // 白
                }
                default -> {
                    return "\033[0m"; // デフォルト
                }
            }
        }
    }

    // =========================================================================
    // 2. Mocklisp (MLisp) 軽量S式パーサ & 実行エンジン
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
                } else if (c == ';') {
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
            pos++;
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
        private final Map<String, List<Object>> userFunctions = new HashMap<>();
        private final List<AutoExecuteRule> autoExecuteRules = new ArrayList<>();

        record AutoExecuteRule(String fnName, String pattern) {}

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

                return callFunction(fnName, args, ed);
            }
            return null;
        }

        public void applyAutoExecute(Editor ed) {
            String fname = Path.of(ed.filename).getFileName().toString();
            for (AutoExecuteRule rule : autoExecuteRules) {
                if (matchesGlob(fname, rule.pattern)) {
                    if (userFunctions.containsKey(rule.fnName)) {
                        for (Object expr : userFunctions.get(rule.fnName)) {
                            eval(expr, ed);
                        }
                        ed.statusMessage = "Executed auto-hook: " + rule.fnName;
                    }
                }
            }
        }

        private boolean matchesGlob(String text, String glob) {
            String regex = "^" + glob.replace(".", "\\.").replace("*", ".*").replace("?", ".") + "$";
            return Pattern.compile(regex, Pattern.CASE_INSENSITIVE).matcher(text).matches();
        }

        private Object callFunction(String fn, List<Object> args, Editor ed) {
            switch (fn) {
                // --- defun (ユーザー関数定義) ---
                case "defun" -> {
                    if (args.isEmpty()) return 0L;
                    String name = null;
                    List<Object> body = new ArrayList<>();

                    // パターンA (Gosling Emacs伝統): (defun (fn-name body1 body2 ...))
                    if (args.get(0) instanceof List<?> fnList && !fnList.isEmpty()) {
                        Object first = fnList.get(0);
                        name = (first instanceof MLSymbol s) ? s.name : String.valueOf(first);
                        for (int i = 1; i < fnList.size(); i++) {
                            body.add(fnList.get(i));
                        }
                    }
                    // パターンB (標準Lisp風): (defun fn-name body1 body2 ...)
                    else if (args.get(0) instanceof MLSymbol sym) {
                        name = sym.name;
                        body.addAll(args.subList(1, args.size()));
                    }

                    if (name != null) {
                        userFunctions.put(name, body);
                        return new MLSymbol(name);
                    }
                    return 0L;
                }

                // --- auto-execute (ファイルパターンに応じた自動実行フック) ---
                case "auto-execute" -> {
                    if (args.size() >= 2) {
                        Object fnArg = eval(args.get(0), ed);
                        Object patArg = eval(args.get(1), ed);
                        String fnName = (fnArg != null) ? fnArg.toString() : "";
                        String pat = (patArg != null) ? patArg.toString() : "";
                        autoExecuteRules.add(new AutoExecuteRule(fnName, pat));
                        return 0L;
                    }
                    return 0L;
                }

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
                    return (long) (ed.cursorY * 1000 + ed.cursorX);
                }
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
                    if (userFunctions.containsKey(fn)) {
                        List<Object> body = userFunctions.get(fn);
                        Object last = 0L;
                        for (Object expr : body) {
                            last = eval(expr, ed);
                        }
                        return last;
                    }
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
    // 3. Editor 本体 (RSyntaxTextArea によるハイライトキャッシュ対応)
    // =========================================================================
    static class Editor {
        String filename;
        List<String> lines = new ArrayList<>(List.of(""));
        List<String> highlightedLines = new ArrayList<>();
        int cursorX = 0;
        int cursorY = 0;
        int rowOffset = 0;
        boolean isModified = false;
        String statusMessage = "";
        boolean running = true;
        boolean prefixCtrlX = false;

        final MLEvaluator mlisp = new MLEvaluator();
        final SyntaxColorizer colorizer;

        Editor(String filename) {
            this.filename = (filename != null && !filename.isBlank()) ? filename : "untitled.txt";
            this.colorizer = new SyntaxColorizer(this.filename);
            loadFile();
            updateHighlight();
            loadInitScript();
            mlisp.applyAutoExecute(this);
        }

        void updateHighlight() {
            highlightedLines.clear();
            for (String l : lines) {
                highlightedLines.add(colorizer.highlightLine(l));
            }
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
            updateHighlight();
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
            updateHighlight();
        }

        void deleteBackward() {
            if (cursorX > 0) {
                String line = currentLine();
                String before = line.substring(0, cursorX - 1);
                String after = line.substring(cursorX);
                lines.set(cursorY, before + after);
                cursorX--;
                isModified = true;
                updateHighlight();
            } else if (cursorY > 0) {
                int prevLen = lines.get(cursorY - 1).length();
                lines.set(cursorY - 1, lines.get(cursorY - 1) + currentLine());
                lines.remove(cursorY);
                cursorY--;
                cursorX = prevLen;
                isModified = true;
                updateHighlight();
            }
        }

        void deleteForward() {
            String line = currentLine();
            if (cursorX < line.length()) {
                String before = line.substring(0, cursorX);
                String after = line.substring(cursorX + 1);
                lines.set(cursorY, before + after);
                isModified = true;
                updateHighlight();
            } else if (cursorY < lines.size() - 1) {
                lines.set(cursorY, line + lines.get(cursorY + 1));
                lines.remove(cursorY + 1);
                isModified = true;
                updateHighlight();
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
            updateHighlight();
        }

        void moveCursor(int dx, int dy) {
            int newY = Math.max(0, Math.min(lines.size() - 1, cursorY + dy));
            if (newY != cursorY) {
                cursorY = newY;
                cursorX = Math.min(cursorX, currentLine().length());
            }

            if (dx > 0) {
                if (cursorX < currentLine().length()) {
                    cursorX++;
                } else if (cursorY < lines.size() - 1) {
                    cursorY++;
                    cursorX = 0;
                }
            } else if (dx < 0) {
                if (cursorX > 0) {
                    cursorX--;
                } else if (cursorY > 0) {
                    cursorY--;
                    cursorX = currentLine().length();
                }
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
                } else if (c == 0x07 || c == 0x1B || c == 0x03) {
                    statusMessage = "Quit";
                    return null;
                } else if (c == 0x7F || c == 0x08) {
                    if (buf.length() > 0) buf.deleteCharAt(buf.length() - 1);
                } else if (c >= 0x20) {
                    buf.append((char) c);
                }
            }
        }

        void setTitle(String title) {
            System.out.printf("\033]0;%s\007", title);
        }

        int termCols = 80;
        int termRows = 24;

        void updateWindowSize() {
            try {
                Process p = new ProcessBuilder("sh", "-c", "stty size < /dev/tty").start();
                try (BufferedReader reader = new BufferedReader(new InputStreamReader(p.getInputStream()))) {
                    String line = reader.readLine();
                    if (line != null) {
                        String[] parts = line.trim().split("\\s+");
                        if (parts.length >= 2) {
                            termRows = Integer.parseInt(parts[0]);
                            termCols = Integer.parseInt(parts[1]);
                            return;
                        }
                    }
                }
            } catch (Exception ignored) {}

            try {
                String colsStr = executeCommand("tput cols 2>/dev/null || echo 80");
                String rowsStr = executeCommand("tput lines 2>/dev/null || echo 24");
                termCols = Integer.parseInt(colsStr.trim());
                termRows = Integer.parseInt(rowsStr.trim());
            } catch (Exception ignored) {}
        }

        int getTerminalCols() { return termCols; }
        int getTerminalRows() { return termRows; }

        void render() {
            int cols = getTerminalCols();
            int rows = getTerminalRows();
            int screenRows = Math.max(1, rows - 1);

            if (cursorY < rowOffset) rowOffset = cursorY;
            if (cursorY >= rowOffset + screenRows) rowOffset = cursorY - screenRows + 1;

            setTitle("inzm (Gosmacs) - " + filename + (isModified ? "*" : ""));

            StringBuilder out = new StringBuilder();
            out.append("\033[?25l");

            // 1. 本文テキストエリア (キャッシュされた RSyntaxTextArea ハイライト行を出力！)
            for (int i = 0; i < screenRows; i++) {
                int fileRow = rowOffset + i;
                out.append(String.format("\033[%d;1H", i + 1));

                if (fileRow < lines.size()) {
                    String lineNum = String.format("%3d ", fileRow + 1);
                    out.append("\033[90m").append(lineNum).append("\033[0m");
                    String text = (fileRow < highlightedLines.size()) ? highlightedLines.get(fileRow) : lines.get(fileRow);
                    out.append(text);
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
            String langTag = colorizer.getLangName();
            String leftStatus = String.format("-%s-  [Gosmacs:%s] %s  (%s)%s  L%d/C%d",
                    modMark, langTag, filename, eawLabel, pfxMark, cursorY + 1, cursorX + 1);
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
            int screenX = visualX + 5;

            out.append(String.format("\033[%d;%dH\033[?25h", screenY, screenX));

            System.out.print(out);
            System.out.flush();
        }

    // =========================================================================
    // 4. メインループ & 入力処理 (エスケープシーケンス完全防壁)
    // =========================================================================
    void run() {
        // どんな終了（Ctrl+Cや異常終了）でも確実に通常画面へ復元するシャットダウンフック
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            try {
                setTitle("");
                System.out.print("\033[?1049l\033[?25h");
                System.out.flush();
                setRawMode(false);
            } catch (Exception ignored) {}
        }));

        setRawMode(true);
        // 代替画面バッファ (Alternate Screen Buffer) に入り、画面を初期化
        System.out.print("\033[?1049h\033[2J\033[H");
        System.out.flush();

        isEaw = probeEaw();
        updateWindowSize();

        // 端末ウィンドウリサイズ (SIGWINCH) をリアルタイム検知して再描画
        try {
            sun.misc.Signal.handle(new sun.misc.Signal("WINCH"), sig -> {
                updateWindowSize();
                if (running) {
                    render();
                }
            });
        } catch (Throwable ignored) {}

        render();

        try {
            while (running) {
                String key = readKeySequence();
                if (key.isEmpty()) continue;

                if (!statusMessage.startsWith("=>") && !statusMessage.startsWith("MLisp error") && !statusMessage.startsWith("Quit")) {
                    statusMessage = "";
                }

                handleKey(key);
                if (running) render();
            }
        } finally {
            setTitle("");
            System.out.print("\033[?1049l\033[?25h");
            System.out.flush();
            setRawMode(false);
        }
    }

    String readKeySequence() {
        try {
            int c = System.in.read();
            if (c == -1) return "";

            if (c == 0x1B) { // ESC
                // 続くバイトの到着を最大40ms待機
                long start = System.currentTimeMillis();
                while (System.in.available() == 0 && (System.currentTimeMillis() - start) < 40) {
                    Thread.sleep(2);
                }
                if (System.in.available() == 0) {
                    return "\033"; // 単独の Esc
                }

                int c2 = System.in.read();
                if (c2 == '[') {
                    StringBuilder seq = new StringBuilder("\033[");
                    start = System.currentTimeMillis();
                    while (System.currentTimeMillis() - start < 40) {
                        if (System.in.available() > 0) {
                            int next = System.in.read();
                            seq.append((char) next);
                            if (Character.isLetter(next) || next == '~') break;
                        } else {
                            Thread.sleep(2);
                        }
                    }
                    return seq.toString();
                } else {
                    return "\033" + (char) c2; // Meta キー (M-:, M-v 等)
                }
            }

            // UTF-8 マルチバイト文字の読み取り
            int bytes = 1;
            if ((c & 0xE0) == 0xC0) bytes = 2;
            else if ((c & 0xF0) == 0xE0) bytes = 3;
            else if ((c & 0xF8) == 0xF0) bytes = 4;

            byte[] buf = new byte[bytes];
            buf[0] = (byte) c;
            for (int i = 1; i < bytes; i++) {
                buf[i] = (byte) System.in.read();
            }
            return new String(buf, StandardCharsets.UTF_8);
        } catch (Exception e) {
            return "";
        }
    }

    void handleKey(String key) {
        // C-x プレフィックス
        if (prefixCtrlX) {
            prefixCtrlX = false;
            if (key.equals("\u0013")) { // C-s
                saveFile();
            } else if (key.equals("\u0003")) { // C-c
                running = false;
            } else {
                statusMessage = "C-x " + key + " is undefined";
            }
            return;
        }

        switch (key) {
            case "\u0018" -> prefixCtrlX = true; // C-x
            case "\u0010", "\033[A" -> moveCursor(0, -1); // C-p / Up
            case "\u000E", "\033[B" -> moveCursor(0, 1);  // C-n / Down
            case "\u0006", "\033[C" -> moveCursor(1, 0);  // C-f / Right
            case "\u0002", "\033[D" -> moveCursor(-1, 0); // C-b / Left
            case "\u0001", "\033[H", "\033[1~" -> cursorX = 0; // C-a / Home
            case "\u0005", "\033[F", "\033[4~" -> cursorX = currentLine().length(); // C-e / End
            case "\033[5~", "\033v" -> moveCursor(0, -(termRows - 1)); // PageUp / M-v
            case "\033[6~", "\u0016" -> moveCursor(0, termRows - 1);  // PageDown / C-v
            case "\033:" -> evalPrompt(); // M-: (Eval Mocklisp)
            case "\u0004" -> deleteForward(); // C-d
            case "\u000B" -> killToEndOfLine(); // C-k
            case "\u0007" -> { // C-g
                prefixCtrlX = false;
                statusMessage = "Quit";
            }
            case "\r", "\n" -> insertNewline();
            case "\u007F", "\u0008" -> deleteBackward();
            default -> {
                // エスケープシーケンスで始まらない通常の表示可能文字のみバッファへ挿入！
                if (!key.startsWith("\033") && !key.isEmpty()) {
                    char first = key.charAt(0);
                    if (first >= 0x20) {
                        insertString(key);
                    }
                }
            }
        }
    }
    }

    // =========================================================================
    // 5. ターミナル生モード制御ヘルパー (/dev/tty 直接制御)
    // =========================================================================
    static void setRawMode(boolean enable) {
        String cmd = enable ? "stty -icanon -echo < /dev/tty" : "stty sane < /dev/tty";
        try {
            new ProcessBuilder("sh", "-c", cmd).inheritIO().start().waitFor();
        } catch (Exception e) {
            try {
                String fallback = enable ? "stty -icanon -echo" : "stty sane";
                new ProcessBuilder("sh", "-c", fallback).inheritIO().start().waitFor();
            } catch (Exception ignored) {}
        }
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
    // 6. エントリポイント
    // =========================================================================
    public static void main(String[] args) {
        String fname = (args.length > 0) ? args[0] : "untitled.txt";
        Editor ed = new Editor(fname);
        ed.run();
    }
}
