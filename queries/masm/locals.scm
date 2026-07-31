; Miden Assembly locals.
;
; Scopes are taken verbatim from the grammar's upstream `queries/locals.scm`
; (https://github.com/0xMiden/tree-sitter-masm @ 3dfc7c1) -- `@local.scope`
; is already Neovim's capture name, so no porting was required.
;
; Definitions and references are OUR addition: upstream ships scopes only,
; which no consumer can act on (nothing links a reference to a definition).
; Procedure, constant and type-alias names are definitions; invocation-path
; identifiers and constant immediates are references. MASM has no shadowing,
; so the flat capture set is faithful.

(procedure) @local.scope

(entrypoint) @local.scope

(if) @local.scope

(while) @local.scope

(repeat) @local.scope

(procedure
  name: (procedure_name
    (identifier) @local.definition.function))

(constant
  name: (const_ident) @local.definition.constant)

(type_alias
  name: (identifier) @local.definition.type)

; `exec.foo` / `call.mod::foo` targets: every path segment is a reference
; (the qualifiers name modules, the last segment the procedure).
(invoke
  path: (path
    (absolute_path
      (identifier) @local.reference)))

(invoke
  path: (path
    (relative_path
      (identifier) @local.reference)))

; Constant immediates (`push.MAX_VALUE`, `assert.err=ERR_CODE`).
(felt_immediate
  (const_ident) @local.reference)

(relative_const_path
  (const_ident) @local.reference)

(absolute_const_path
  (const_ident) @local.reference)
