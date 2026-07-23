; Miden Assembly highlights.
;
; Ported from the official grammar's Zed queries:
;   https://github.com/0xMiden/tree-sitter-masm  @ 3dfc7c1
;
; Deltas vs upstream (see CONTRIBUTING.md "Porting queries" for why we vendor
; these; the parser pin lives in plugin/miden-masm.lua):
;   * @comment.doc            -> @comment.documentation  (nvim capture name)
;   * @parameter              -> @variable.parameter     (nvim capture name)
;   * @punctuation.list_marker: dropped, Zed-only and shadowed by
;                               @punctuation.bracket on the same nodes
;   * (entrypoint) @function  : dropped, the node spans the whole `begin..end`
;                               block and would tint the entire program

(doc_comment) @comment.documentation

(comment) @comment

(visibility) @keyword
(primitive_type) @type.builtin
(int_type) @type.builtin
(address_space) @type.builtin

[
  "use"
  "const"
  "adv_map"
  "begin"
  "end"
  "proc"
  "type"
  "enum"
  "struct"
  "if"
  "else"
  "while"
  "repeat"
  "true"
  "false"
  "adv"
  "insert_hdword"
  "insert_hdword_d"
  "insert_hqword"
  "insert_hperm"
  "insert_mem"
  "push_mapval"
  "push_mapval_count"
  "push_mapvaln"
  "has_mapkey"
  "push_mtnode"
  "adv_pipe"
  "adv_loadw"
  "and"
  "eval_circuit"
  "caller"
  "cdrop"
  "cdropw"
  "clk"
  "crypto_stream"
  "cswap"
  "cswapw"
  "drop"
  "dropw"
  "dyncall"
  "dynexec"
  "eqw"
  "ext2add"
  "ext2div"
  "ext2inv"
  "ext2mul"
  "ext2neg"
  "ext2sub"
  "fri_ext2fold4"
  "hash"
  "hperm"
  "hmerge"
  "ilog2"
  "inv"
  "is_odd"
  "mem_stream"
  "mtree_get"
  "mtree_merge"
  "mtree_set"
  "neg"
  "not"
  "nop"
  "or"
  "padw"
  "pow2"
  "horner_eval_base"
  "horner_eval_ext"
  "log_precompile"
  "reversew"
  "reversedw"
  "sdepth"
  "swapdw"
  "u32cast"
  "u32overflowing_add3"
  "u32widening_add3"
  "u32widening_madd"
  "u32popcnt"
  "u32clz"
  "u32ctz"
  "u32clo"
  "u32cto"
  "u32split"
  "u32test"
  "u32testw"
  "u32wrapping_add3"
  "u32wrapping_madd"
  "xor"
  "add"
  "sub"
  "mul"
  "div"
  "eq"
  "exp"
  "exp.u"
  "gt"
  "gte"
  "lt"
  "lte"
  "neq"
  "u32div"
  "u32divmod"
  "u32mod"
  "u32and"
  "u32or"
  "u32xor"
  "u32not"
  "u32wrapping_add"
  "u32wrapping_sub"
  "u32wrapping_mul"
  "u32overflowing_add"
  "u32widening_add"
  "u32overflowing_sub"
  "u32widening_mul"
  "u32shl"
  "u32shr"
  "u32rotl"
  "u32rotr"
  "u32lt"
  "u32lte"
  "u32gt"
  "u32gte"
  "u32min"
  "u32max"
  "mem_load"
  "mem_loadw"
  "mem_loadw_be"
  "mem_loadw_le"
  "mem_store"
  "mem_storew"
  "mem_storew_be"
  "mem_storew_le"
  "locaddr"
  "loc_load"
  "loc_loadw"
  "loc_loadw_be"
  "loc_loadw_le"
  "loc_store"
  "loc_storew"
  "loc_storew_be"
  "loc_storew_le"
  "adv_push"
  "dup"
  "dupw"
  "movdn"
  "movdnw"
  "movup"
  "movupw"
  "swap"
  "swapw"
  "assert"
  "assertz"
  "assert_eq"
  "assert_eqw"
  "u32assert"
  "u32assert2"
  "u32assertw"
  "mtree_verify"
  "debug"
  "emit"
  "trace"
  "push"
  "exec"
  "call"
  "syscall"
  "procref"
  "event"
  "err"
] @keyword

(const_ident) @constant

; Catch-all for bare identifiers (instruction targets like `exec.foo`). In
; Neovim, LATER patterns win on ties -- the reverse of Zed, where this sits
; last. It must precede the specific identifier patterns below
; (@variable.parameter, @attribute, @function, ...) or it overrides them all.
(identifier) @function.method

(type_alias
  name: (identifier) @type)

(enum_declaration
  name: (identifier) @type)

(struct_field
  name: (identifier) @property)

(function_param
  name: (identifier) @variable.parameter)

(function_result
  name: (identifier) @variable.parameter)

(annotation
  name: (identifier) @attribute)

(meta_key_value
  name: (identifier) @property)

(import_alias
  name: (identifier) @module)

(import_alias
  name: (quoted_ident) @module)

(procedure
  name: (procedure_name
    (identifier) @function))

(procedure
  name: (procedure_name
    (quoted_ident) @function))

((identifier) @string.special.symbol
  (#match? @string.special.symbol "^[$](exec|kernel)$"))

[
  (integer)
  (decimal)
  (hex)
  (hex_word)
  (binary)
  (word)
] @number

(string) @string
(quoted_ident) @string

[
  "+"
  "-"
  "*"
  "/"
  "//"
  "="
  "->"
] @operator

[
  "."
  "::"
  ","
  ";"
  ":"
  ".."
] @punctuation.delimiter

[
  "["
  "]"
  "("
  ")"
  "{"
  "}"
  "<"
  ">"
] @punctuation.bracket
