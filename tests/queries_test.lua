-- Validates the tree-sitter queries against the pinned grammar: each query
-- must parse AND produce at least one capture on the fixture sources (a
-- query full of impossible patterns parses fine but matches nothing).
-- Run with `make test-queries`, which builds the parser first.

local script = debug.getinfo(1, "S").source:sub(2)
local here = vim.fs.dirname(vim.fn.fnamemodify(script, ":p"))
local plugin_root = vim.fs.dirname(here)
vim.opt.rtp:prepend(plugin_root)
vim.opt.rtp:prepend(here .. "/.parser-build") -- provides parser/masm.so

local function read(path)
  local fh = assert(io.open(path), "cannot open " .. path)
  local s = fh:read("*a")
  fh:close()
  return s
end

local sources = {}
for _, f in ipairs({ "app/main.masm", "core_lib/math.masm", "std_lib/wrappers.masm" }) do
  sources[#sources + 1] = read(here .. "/fixtures/" .. f)
end

local failed = 0
for _, qname in ipairs({ "highlights", "indents", "folds", "locals", "textobjects" }) do
  local src = read(plugin_root .. "/queries/masm/" .. qname .. ".scm")
  local ok, query = pcall(vim.treesitter.query.parse, "masm", src)
  if not ok then
    print("FAIL: " .. qname .. " does not parse: " .. tostring(query))
    failed = failed + 1
  else
    local captures = 0
    for _, text in ipairs(sources) do
      local parser = vim.treesitter.get_string_parser(text, "masm")
      local tree = parser:parse()[1]
      for _ in query:iter_captures(tree:root(), text) do
        captures = captures + 1
      end
    end
    if captures == 0 then
      print("FAIL: " .. qname .. " matched nothing on the fixtures")
      failed = failed + 1
    else
      print(string.format("PASS: %s (%d captures)", qname, captures))
    end
  end
end

print(failed == 0 and "ALL PASS" or (failed .. " FAILURES"))
if failed > 0 then
  os.exit(1)
end
