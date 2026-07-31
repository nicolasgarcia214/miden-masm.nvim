; Miden Assembly indentation.
;
; NOT a port of the grammar's upstream `queries/indents.scm`: that file uses
; Zed's `@indent` / `@end` capture pair, which Neovim's indent module does not
; understand at all. Rewritten here against nvim-treesitter's
; `@indent.begin` / `@indent.end` / `@indent.branch` convention, modelled on
; the bundled Lua queries since Miden MASM is likewise an `end`-delimited
; language.

; `(word)` is the multi-line word-literal form (`[1, 0, 0,\n 0]` spanning
; lines): upstream indents it too (`(word "]" @end) @indent`), and its `]`
; is dedented by @indent.end/@indent.branch below exactly like `end`.
[
  (procedure)
  (entrypoint)
  (if)
  (while)
  (repeat)
  (enum_declaration)
  (struct_type)
  (word)
  (array_type)
] @indent.begin

[
  "end"
  "}"
  "]"
] @indent.end

; Dedent the line that carries the closing token itself, so `end` and `else`
; line up with the keyword that opened the block rather than with its body.
[
  "end"
  "else"
  "}"
  "]"
] @indent.branch

; Keep the previous line's indent inside comments instead of re-deriving it.
[
  (comment)
  (doc_comment)
] @indent.auto
