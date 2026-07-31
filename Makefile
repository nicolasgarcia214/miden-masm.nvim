# Single source of truth for the grammar pin: plugin/miden-masm.lua. Deriving
# it here means test-queries always validates the exact revision users install.
PARSER_REV := $(shell sed -n 's/.*revision = "\([0-9a-f]\{40\}\)".*/\1/p' plugin/miden-masm.lua)
PARSER_BUILD := tests/.parser-build

.PHONY: test test-queries
test:
	nvim --headless --clean -l tests/masm_test.lua
	nvim --headless --clean -l tests/hover_test.lua
	nvim --headless --clean -l tests/stack_test.lua
	nvim --headless --clean -l tests/complete_test.lua
	nvim --headless --clean -l tests/dap_test.lua
	nvim --headless --clean -l tests/ftplugin_test.lua

test-queries: $(PARSER_BUILD)/parser/masm.so
	nvim --headless --clean -l tests/queries_test.lua

$(PARSER_BUILD)/parser/masm.so:
	mkdir -p $(PARSER_BUILD)/parser
	test -d $(PARSER_BUILD)/tree-sitter-masm || \
		git clone --quiet https://github.com/0xMiden/tree-sitter-masm $(PARSER_BUILD)/tree-sitter-masm
	git -C $(PARSER_BUILD)/tree-sitter-masm checkout --quiet $(PARSER_REV)
	cc -o $@ -shared -fPIC -I $(PARSER_BUILD)/tree-sitter-masm/src $(PARSER_BUILD)/tree-sitter-masm/src/*.c
