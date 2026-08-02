local pass, fail = 0, 0

local function ok(cond, msg)
  if cond then
    pass = pass + 1
    print("PASS: " .. msg)
  else
    fail = fail + 1
    print("FAIL: " .. msg)
  end
end

local function buf_from_lines(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

local diffedit = require("diffedit")

-- 1. recalc fixes counts in both hunks, preserves section tail
local sample = {
  "diff --git a/src/server.lua b/src/server.lua",
  "index abc123..def456 100644",
  "--- a/src/server.lua",
  "+++ b/src/server.lua",
  "@@ -12,7 +12,8 @@ local M = {}",
  "     local port = vim.env.PORT or 8080",
  "     M.start = function(opts)",
  "+        M.listen(port)",
  "         M.handler = opts.handler",
  "-        M.port = port",
  "+        M.port = port",
  "     end",
  "@@ -25,6 +27,7 @@ end",
  "     return M",
  " end",
  "+-- new footer",
}
local b1 = buf_from_lines(sample)
diffedit._recalc(b1)
local got = vim.api.nvim_buf_get_lines(b1, 0, -1, false)
ok(got[5] == "@@ -12,5 +12,6 @@ local M = {}", "hunk1 counts recalculated, tail kept (got: " .. got[5] .. ")")
ok(got[13] == "@@ -25,2 +27,3 @@ end", "hunk2 counts recalculated (got: " .. got[13] .. ")")
ok(got[6] == sample[6], "context lines untouched")

-- 2. recalc is idempotent
diffedit._recalc(b1)
local got2 = vim.api.nvim_buf_get_lines(b1, 0, -1, false)
ok(vim.deep_equal(got, got2), "recalc is idempotent")

-- 3. header with omitted counts parsed correctly
local h = diffedit._parse_hunk_header("@@ -12 +13,8 @@ foo")
ok(h and h.ostart == 12 and h.ocount == 1 and h.nstart == 13 and h.ncount == 8, "omitted old count defaults to 1")

-- 4. non-hunk line returns nil
ok(diffedit._parse_hunk_header("     some context") == nil, "context line is not a hunk header")
ok(diffedit._parse_hunk_header("--- a/foo") == nil, "file header is not a hunk header")

-- 5. o on a + line inserts a prefixed line below with indent
local b2 = buf_from_lines({
  "+        M.listen(port)",
  "         M.handler = opts.handler",
})
vim.api.nvim_win_set_buf(0, b2)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_win_call(0, function()
  diffedit._open_line(false)
end)
local b2lines = vim.api.nvim_buf_get_lines(b2, 0, -1, false)
ok(b2lines[2] == "+        ", "o on + line inserts '+<indent>' (got: [" .. (b2lines[2] or "nil") .. "])")

-- 6. O on a - line inserts above
vim.api.nvim_buf_set_lines(b2, 0, -1, false, { "-        M.port = port", "     end" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_win_call(0, function()
  diffedit._open_line(true)
end)
b2lines = vim.api.nvim_buf_get_lines(b2, 0, -1, false)
ok(b2lines[1] == "-        ", "O on - line inserts '-<indent>' above (got: [" .. (b2lines[1] or "nil") .. "])")

-- 7. validate flags a stray + line outside hunks as ERROR
local b3 = buf_from_lines({
  "--- a/foo.lua",
  "+++ b/foo.lua",
  "+        stray line",
  "@@ -1,2 +1,2 @@ x",
  " a",
  " b",
})
vim.api.nvim_buf_call(b3, function()
  diffedit._validate(b3)
end)
local diags = vim.diagnostic.get(b3)
ok(#diags == 1, "validate flags exactly one stray line (got " .. #diags .. ")")
if #diags == 1 then
  ok(diags[1].severity == vim.diagnostic.severity.ERROR, "stray line is an ERROR")
end

-- 8. validate reports count mismatch as WARN
local b4 = buf_from_lines({
  "--- a/foo.lua",
  "+++ b/foo.lua",
  "@@ -1,9 +1,9 @@ x",
  " a",
  " b",
})
vim.api.nvim_buf_call(b4, function()
  diffedit._validate(b4)
end)
diags = vim.diagnostic.get(b4)
ok(#diags >= 1, "count mismatch reported (got " .. #diags .. ")")

-- 9. highlight runs without error (best-effort; may no-op if no parser)
local b5 = buf_from_lines({
  "--- a/x.lua",
  "+++ b/x.lua",
  "@@ -1,2 +1,3 @@",
  " local function foo()",
  "+  return 1",
})
local ok_hl = pcall(diffedit._highlight, b5)
ok(ok_hl, "highlight does not error")

-- 10. o on a file header line does not insert a body line
local b6 = buf_from_lines({
  "--- a/x.lua",
  "+++ b/x.lua",
})
vim.api.nvim_win_set_buf(0, b6)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_win_call(0, function()
  diffedit._open_line(false)
end)
local b6lines = vim.api.nvim_buf_get_lines(b6, 0, -1, false)
ok(#b6lines == 2, "o on --- file header does not insert a line")

-- 11. a + line added at the end of a hunk is absorbed on recalc
local b7 = buf_from_lines({
  "--- a/x.lua",
  "+++ b/x.lua",
  "@@ -1,2 +1,2 @@",
  " a",
  " b",
})
diffedit._recalc(b7)
vim.api.nvim_buf_set_lines(b7, 3, 3, false, { "+  c" })
diffedit._recalc(b7)
b7lines = vim.api.nvim_buf_get_lines(b7, 0, -1, false)
ok(b7lines[3] == "@@ -1,2 +1,3 @@", "+ line at hunk edge absorbed (got: " .. b7lines[3] .. ")")

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
