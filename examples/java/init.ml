;; init.ml - Mocklisp (MLisp) startup script for inzm (Gosling Emacs homage)
;; This file is evaluated on startup by the built-in Mocklisp interpreter.

(setq tab-width 4)
(setq editor-name "Gosmacs in Java")

;; 1. defun: Gosling Emacs 伝統構文による関数定義
(defun
    (c-comment-box
        (beginning-of-line)
        (insert-string "/* === Mocklisp Defined Function === */\n")
    )
)

;; 2. auto-execute: ファイル名パターンに基づく自動実行フック (UniPress/Gosmacs仕様)
(auto-execute "c-comment-box" "*.ml")

;; Display startup greeting in the minibuffer
(message "Welcome to Gosling Emacs homage! Mocklisp ready.")
