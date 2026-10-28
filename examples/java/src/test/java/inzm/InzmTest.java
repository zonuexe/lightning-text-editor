package inzm;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

public class InzmTest {

    @Test
    public void testMocklispDefunAndAutoExecute() {
        Inzm.Editor ed = new Inzm.Editor("test.ml");

        // defun の評価
        String defunCode = """
            (defun (my-greeting
                (beginning-of-line)
                (insert-string "Hello from defun!\\n")
            ))
            """;
        Inzm.MLParser parser = new Inzm.MLParser(defunCode);
        for (Object expr : parser.parseAll()) {
            ed.mlisp.eval(expr, ed);
        }

        // ユーザー関数の呼び出し
        Inzm.MLParser callParser = new Inzm.MLParser("(my-greeting)");
        ed.mlisp.eval(callParser.parseExpr(), ed);

        assertTrue(ed.lines.get(0).contains("Hello from defun!"));
    }

    @Test
    public void testSyntaxColorizerLanguages() {
        assertEquals("PHP", new Inzm.SyntaxColorizer("index.php").getLangName());
        assertEquals("Shell", new Inzm.SyntaxColorizer("script.sh").getLangName());
        assertEquals("Go", new Inzm.SyntaxColorizer("main.go").getLangName());
        assertEquals("Rust", new Inzm.SyntaxColorizer("main.rs").getLangName());
        assertEquals("TypeScript", new Inzm.SyntaxColorizer("app.ts").getLangName());
        assertEquals("Markdown", new Inzm.SyntaxColorizer("README.md").getLangName());
        assertEquals("JSON", new Inzm.SyntaxColorizer("data.json").getLangName());
        assertEquals("Lisp", new Inzm.SyntaxColorizer("init.ml").getLangName());

        // PHPのハイライト出力をテスト
        Inzm.SyntaxColorizer phpColorizer = new Inzm.SyntaxColorizer("test.php");
        String highlighted = phpColorizer.highlightLine("<?php echo 'hello';");
        assertTrue(highlighted.contains("\033["), "PHP line should contain ANSI color codes");
    }
}
