# Single source of truth for the grammar pin: plugin/miden-masm.lua. Deriving
# it here means test-queries always validates the exact revision users install.
PARSER_REV := $(shell sed -n 's/.*revision = "\([0-9a-f]\{40\}\)".*/\1/p' plugin/miden-masm.lua)
PARSER_BUILD := tests/.parser-build

.PHONY: test test-queries lint check fmt
test:
	nvim --headless --clean -l tests/masm_test.lua
	nvim --headless --clean -l tests/hover_test.lua
	nvim --headless --clean -l tests/stack_test.lua
	nvim --headless --clean -l tests/complete_test.lua
	nvim --headless --clean -l tests/dap_test.lua
	nvim --headless --clean -l tests/health_test.lua
	nvim --headless --clean -l tests/consistency_test.lua
	nvim --headless --clean -l tests/ftplugin_test.lua
	nvim --headless --clean -l tests/hardening_test.lua

test-queries: $(PARSER_BUILD)/parser/masm.so
	nvim --headless --clean -l tests/queries_test.lua

# Static analysis (config in .luacheckrc). Install luacheck via your package
# manager, `luarocks install luacheck`, or the standalone binary from
# https://github.com/lunarmodules/luacheck/releases (CI pins v1.2.0).
# `scripts` is included for bench.lua; luacheck only picks up .lua files
# from a directory, so the Python generator there is naturally skipped.
lint:
	luacheck lua plugin after tests scripts

# Type check (zero problems is the bar; CI enforces it). The checked-in
# .luarc.json points workspace.library at $VIMRUNTIME/lua for the vim API
# type definitions, so VIMRUNTIME is derived from the installed nvim here --
# one config works on any machine and in CI. Those definitions ship WITH
# Neovim, so an nvim older than CI's pinned one (v0.12.4) can report noise
# this repo does not count as failures. Install lua-language-server via your
# package manager or the release tarball (CI pins v3.15.0 by checksum).
check:
	VIMRUNTIME="$$(nvim --clean --headless -c 'lua io.write(vim.env.VIMRUNTIME)' -c 'quit' 2>/dev/null)" \
		lua-language-server --check . --checklevel=Warning

# Rewrite formatting in place -- the local fix-it counterpart to CI's stylua
# job, which runs `--check` and hard-fails. Same pinned version as CI.
fmt:
	npx --yes @johnnymorganz/stylua-bin@2.5.2 .

$(PARSER_BUILD)/parser/masm.so:
	mkdir -p $(PARSER_BUILD)/parser
	test -d $(PARSER_BUILD)/tree-sitter-masm || \
		git clone --quiet https://github.com/0xMiden/tree-sitter-masm $(PARSER_BUILD)/tree-sitter-masm
	git -C $(PARSER_BUILD)/tree-sitter-masm checkout --quiet $(PARSER_REV)
	cc -o $@ -shared -fPIC -I $(PARSER_BUILD)/tree-sitter-masm/src $(PARSER_BUILD)/tree-sitter-masm/src/*.c
