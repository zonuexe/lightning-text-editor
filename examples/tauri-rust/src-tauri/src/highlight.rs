//! Lightweight per-line ANSI TrueColor syntax highlighter.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Language {
    Plain,
    Rust,
    TypeScript,
    Python,
    Go,
    Zig,
    MoonBit,
    Markdown,
    Json,
    Toml,
}

impl Language {
    pub fn from_path(path: Option<&str>) -> Self {
        let Some(p) = path else {
            return Self::Plain;
        };
        let lower = p.to_ascii_lowercase();
        if lower.ends_with(".rs") {
            Self::Rust
        } else if lower.ends_with(".ts")
            || lower.ends_with(".tsx")
            || lower.ends_with(".js")
            || lower.ends_with(".jsx")
            || lower.ends_with(".mjs")
        {
            Self::TypeScript
        } else if lower.ends_with(".py") {
            Self::Python
        } else if lower.ends_with(".go") {
            Self::Go
        } else if lower.ends_with(".zig") {
            Self::Zig
        } else if lower.ends_with(".mbt") {
            Self::MoonBit
        } else if lower.ends_with(".md") || lower.ends_with(".markdown") {
            Self::Markdown
        } else if lower.ends_with(".json") {
            Self::Json
        } else if lower.ends_with(".toml") {
            Self::Toml
        } else {
            Self::Plain
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Plain => "Plain",
            Self::Rust => "Rust",
            Self::TypeScript => "TS/JS",
            Self::Python => "Python",
            Self::Go => "Go",
            Self::Zig => "Zig",
            Self::MoonBit => "MoonBit",
            Self::Markdown => "Markdown",
            Self::Json => "JSON",
            Self::Toml => "TOML",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TokenKind {
    Normal,
    Keyword,
    Type,
    String,
    Number,
    Comment,
    Function,
    Heading,
}

impl TokenKind {
    /// TrueColor SGR foreground color (Catppuccin Mocha palette).
    pub fn fg_ansi(self) -> &'static str {
        match self {
            Self::Normal => "",
            Self::Keyword => "\x1b[38;2;203;166;247m",  // Mauve
            Self::Type => "\x1b[38;2;249;226;175m",     // Yellow
            Self::String => "\x1b[38;2;166;227;161m",   // Green
            Self::Number => "\x1b[38;2;250;179;135m",   // Peach
            Self::Comment => "\x1b[38;2;108;112;134m",  // Overlay0
            Self::Function => "\x1b[38;2;137;180;250m", // Blue
            Self::Heading => "\x1b[1;38;2;137;220;235m",// Bold Sky
        }
    }
}

/// Returns per-byte `TokenKind` across `line`.
pub fn tokenize_line(lang: Language, line: &str) -> Vec<TokenKind> {
    let bytes = line.as_bytes();
    let mut kinds = vec![TokenKind::Normal; bytes.len()];
    if lang == Language::Plain || bytes.is_empty() {
        return kinds;
    }

    if lang == Language::Markdown {
        let trimmed = line.trim_start();
        if trimmed.starts_with('#') {
            kinds.fill(TokenKind::Heading);
            return kinds;
        }
        if trimmed.starts_with("```") || trimmed.starts_with('>') {
            kinds.fill(TokenKind::Comment);
            return kinds;
        }
    }

    let hash_comment = matches!(lang, Language::Python | Language::Toml);
    let slash_comment = matches!(
        lang,
        Language::Rust | Language::TypeScript | Language::Go | Language::Zig | Language::MoonBit
    );

    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];

        // Comments to end of line
        if (hash_comment && b == b'#')
            || (slash_comment && b == b'/' && i + 1 < bytes.len() && bytes[i + 1] == b'/')
        {
            for k in &mut kinds[i..] {
                *k = TokenKind::Comment;
            }
            break;
        }

        // Strings "..." or '...' (when not Rust lifetime)
        if b == b'"' || (b == b'\'' && lang != Language::Rust) {
            let quote = b;
            let start = i;
            i += 1;
            while i < bytes.len() {
                if bytes[i] == b'\\' && i + 1 < bytes.len() {
                    i += 2;
                    continue;
                }
                if bytes[i] == quote {
                    i += 1;
                    break;
                }
                i += 1;
            }
            for k in &mut kinds[start..i] {
                *k = TokenKind::String;
            }
            continue;
        }

        // Rust / TypeScript backtick or raw char literal
        if b == b'`' && matches!(lang, Language::TypeScript | Language::Go | Language::Markdown) {
            let start = i;
            i += 1;
            while i < bytes.len() && bytes[i] != b'`' {
                i += 1;
            }
            if i < bytes.len() {
                i += 1;
            }
            for k in &mut kinds[start..i] {
                *k = TokenKind::String;
            }
            continue;
        }

        // Numbers
        if b.is_ascii_digit()
            && (i == 0 || !is_ident_cont(bytes[i - 1]))
        {
            let start = i;
            while i < bytes.len()
                && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_' || bytes[i] == b'.')
            {
                i += 1;
            }
            for k in &mut kinds[start..i] {
                *k = TokenKind::Number;
            }
            continue;
        }

        // Identifiers / keywords
        if is_ident_start(b) {
            let start = i;
            i += 1;
            while i < bytes.len() && is_ident_cont(bytes[i]) {
                i += 1;
            }
            let word = &line[start..i];
            let kind = if is_keyword(lang, word) {
                TokenKind::Keyword
            } else if bytes.get(i) == Some(&b'(') {
                TokenKind::Function
            } else if word.chars().next().is_some_and(|c| c.is_ascii_uppercase())
                || is_builtin_type(lang, word)
            {
                TokenKind::Type
            } else {
                TokenKind::Normal
            };
            for k in &mut kinds[start..i] {
                *k = kind;
            }
            continue;
        }

        i += 1;
    }

    kinds
}

fn is_ident_start(b: u8) -> bool {
    b.is_ascii_alphabetic() || b == b'_'
}

fn is_ident_cont(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

fn is_keyword(lang: Language, w: &str) -> bool {
    match lang {
        Language::Rust => matches!(
            w,
            "fn" | "let"
                | "mut"
                | "const"
                | "pub"
                | "struct"
                | "enum"
                | "impl"
                | "trait"
                | "for"
                | "in"
                | "while"
                | "loop"
                | "if"
                | "else"
                | "match"
                | "return"
                | "use"
                | "mod"
                | "crate"
                | "self"
                | "Self"
                | "super"
                | "where"
                | "async"
                | "await"
                | "move"
                | "ref"
                | "type"
                | "true"
                | "false"
        ),
        Language::TypeScript => matches!(
            w,
            "const"
                | "let"
                | "var"
                | "function"
                | "return"
                | "if"
                | "else"
                | "for"
                | "of"
                | "in"
                | "while"
                | "switch"
                | "case"
                | "break"
                | "continue"
                | "import"
                | "export"
                | "from"
                | "default"
                | "async"
                | "await"
                | "type"
                | "interface"
                | "class"
                | "new"
                | "try"
                | "catch"
                | "throw"
                | "true"
                | "false"
                | "null"
                | "undefined"
        ),
        Language::Python => matches!(
            w,
            "def"
                | "class"
                | "return"
                | "if"
                | "elif"
                | "else"
                | "for"
                | "in"
                | "while"
                | "import"
                | "from"
                | "as"
                | "with"
                | "try"
                | "except"
                | "finally"
                | "raise"
                | "pass"
                | "break"
                | "continue"
                | "and"
                | "or"
                | "not"
                | "is"
                | "lambda"
                | "yield"
                | "async"
                | "await"
                | "True"
                | "False"
                | "None"
        ),
        Language::Go => matches!(
            w,
            "func"
                | "var"
                | "const"
                | "type"
                | "struct"
                | "interface"
                | "package"
                | "import"
                | "return"
                | "if"
                | "else"
                | "for"
                | "range"
                | "switch"
                | "case"
                | "default"
                | "break"
                | "continue"
                | "go"
                | "defer"
                | "select"
                | "chan"
                | "map"
                | "true"
                | "false"
                | "nil"
        ),
        Language::Zig => matches!(
            w,
            "const"
                | "var"
                | "fn"
                | "pub"
                | "struct"
                | "enum"
                | "union"
                | "if"
                | "else"
                | "while"
                | "for"
                | "switch"
                | "return"
                | "break"
                | "continue"
                | "try"
                | "catch"
                | "defer"
                | "errdefer"
                | "comptime"
                | "inline"
                | "true"
                | "false"
                | "null"
                | "undefined"
        ),
        Language::MoonBit => matches!(
            w,
            "fn" | "let"
                | "mut"
                | "pub"
                | "struct"
                | "enum"
                | "type"
                | "impl"
                | "trait"
                | "if"
                | "else"
                | "match"
                | "for"
                | "in"
                | "while"
                | "loop"
                | "return"
                | "break"
                | "continue"
                | "derive"
                | "true"
                | "false"
        ),
        Language::Json => matches!(w, "true" | "false" | "null"),
        Language::Toml => matches!(w, "true" | "false"),
        Language::Plain | Language::Markdown => false,
    }
}

fn is_builtin_type(lang: Language, w: &str) -> bool {
    match lang {
        Language::Rust => matches!(
            w,
            "usize"
                | "isize"
                | "u8"
                | "u16"
                | "u32"
                | "u64"
                | "i8"
                | "i16"
                | "i32"
                | "i64"
                | "f32"
                | "f64"
                | "bool"
                | "char"
                | "str"
                | "String"
                | "Vec"
                | "Option"
                | "Result"
        ),
        Language::TypeScript => matches!(
            w,
            "string" | "number" | "boolean" | "void" | "unknown" | "never" | "any"
        ),
        Language::Go => matches!(
            w,
            "int" | "string" | "bool" | "byte" | "rune" | "error" | "float64" | "uint"
        ),
        Language::Zig => matches!(
            w,
            "usize" | "isize" | "u8" | "u16" | "u32" | "u64" | "i32" | "i64" | "bool" | "void"
        ),
        Language::MoonBit => matches!(w, "Int" | "String" | "Bool" | "Unit" | "Array" | "Bytes"),
        _ => false,
    }
}
