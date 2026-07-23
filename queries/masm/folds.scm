; Miden Assembly folds.
;
; No upstream counterpart -- Zed does not use fold queries, so this is written
; from scratch. Fold the block constructs; `doc_comment` is included so a
; multi-line `#!` doc block folds down to one line (it is a sibling of the
; procedure node, so it forms its own fold region, not part of the proc's).

[
  (procedure)
  (entrypoint)
  (if)
  (while)
  (repeat)
  (enum_declaration)
  (struct_type)
  (doc_comment)
] @fold
