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
}
