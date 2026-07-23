; Miden Assembly textobjects (nvim-treesitter-textobjects).
;
; Ported from the grammar's upstream `queries/textobjects.scm`
; (https://github.com/0xMiden/tree-sitter-masm @ 3dfc7c1), which uses Zed's
; `.inside` / `.around` suffixes. Neovim uses `.inner` / `.outer`.
;
; This is what makes LazyVim's built-in `]f` / `[f` (next/previous function) and
; the `af` / `if` operators work in `.masm` buffers.

(procedure
  body: (block) @function.inner) @function.outer

(entrypoint
  body: (block) @function.inner) @function.outer

(doc_comment
  (doc_comment_line)+ @comment.inner) @comment.outer

(comment) @comment.outer

; No upstream equivalent: gives `ab` / `ib` on the control-flow blocks.
; `if` has no `body` field -- its branches are `then_body` / `else_body`.
(if
  then_body: (block) @block.inner) @block.outer

(if
  else_body: (block) @block.inner) @block.outer

(while
  body: (block) @block.inner) @block.outer

(repeat
  body: (block) @block.inner) @block.outer
