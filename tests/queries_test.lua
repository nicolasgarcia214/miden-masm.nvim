-- Validates the tree-sitter queries against the pinned grammar: each query
-- must parse AND produce at least one capture on the fixture sources (a
-- query full of impossible patterns parses fine but matches nothing).
-- Run with `make test-queries`, which builds the parser first.

local helpers = dofile(
  vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")) .. "/helpers.lua"
)
local here = helpers.here
local plugin_root = helpers.plugin_root
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

for _, qname in ipairs({ "highlights", "indents", "folds", "locals", "textobjects" }) do
  local src = read(plugin_root .. "/queries/masm/" .. qname .. ".scm")
  local ok, query = pcall(vim.treesitter.query.parse, "masm", src)
  if not ok then
    print("FAIL: " .. qname .. " does not parse: " .. tostring(query))
    helpers.failed = helpers.failed + 1
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
      helpers.failed = helpers.failed + 1
    else
      print(string.format("PASS: %s (%d captures)", qname, captures))
    end
  end
end

-- locals must be actionable, not scopes-only: definition and reference
-- captures both fire on the fixtures (regression: the file shipped inert,
-- with nothing for a consumer to link).
do
  local src = read(plugin_root .. "/queries/masm/locals.scm")
  local ok, query = pcall(vim.treesitter.query.parse, "masm", src)
  local kinds = {}
  if ok then
    for _, text in ipairs(sources) do
      local parser = vim.treesitter.get_string_parser(text, "masm")
      local tree = parser:parse()[1]
      for id in query:iter_captures(tree:root(), text) do
        local name = query.captures[id]
        kinds[name:match("^[%w]+%.[%w]+")] = true
      end
    end
  end
  if ok and kinds["local.definition"] and kinds["local.reference"] and kinds["local.scope"] then
    print("PASS: locals has scope, definition and reference captures")
  else
    print("FAIL: locals lacks definition/reference captures: " .. vim.inspect(kinds))
    helpers.failed = helpers.failed + 1
  end
end

helpers.finish()
