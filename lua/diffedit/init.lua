local M = {}

local hl_ns = vim.api.nvim_create_namespace("diffedit_hl")
local diag_ns = vim.api.nvim_create_namespace("diffedit")

local defaults = {
  hl_code = true,
  hl_group = function(capture, lang)
    return "@" .. capture .. "." .. lang
  end,
}

local opts = vim.tbl_deep_extend("force", {}, defaults, {})

local function is_file_header(line)
  return line:match("^%-%-%-%s") or line:match("^%+%+%+%s")
end

local function is_body(line)
  if is_file_header(line) then
    return false
  end
  local c = line:sub(1, 1)
  return c == " " or c == "+" or c == "-" or c == "\\"
end

local function parse_hunk_header(line)
  local inside = line:match("^@@%s+(.-)%s+@@")
  local tail = line:match("^@@%s+.-%s+@@(.*)$")
  if not inside then
    return nil
  end
  local old, new = inside:match("^(%S+) (%S+)$")
  if not old then
    return nil
  end
  local ostart = tonumber(old:match("^%-(%d+)"))
  local nstart = tonumber(new:match("^%+(%d+)"))
  if not ostart or not nstart then
    return nil
  end
  return {
    ostart = ostart,
    nstart = nstart,
    ocount = tonumber(old:match("^%-%d+,(%d+)")) or 1,
    ncount = tonumber(new:match("^%+%d+,(%d+)")) or 1,
    tail = tail or "",
  }
end

local function format_hunk(h)
  local function one(start, count)
    if count == 1 then
      return tostring(start)
    end
    return string.format("%d,%d", start, count)
  end
  return string.format("@@ -%s +%s @@%s", one(h.ostart, h.ocount), one(h.nstart, h.ncount), h.tail)
end

local function count_hunk(lines, i)
  local ctx, add, del = 0, 0, 0
  local j = i + 2
  while j <= #lines and is_body(lines[j]) do
    local p = lines[j]:sub(1, 1)
    if p == "+" then
      add = add + 1
    elseif p == "-" then
      del = del + 1
    elseif p == " " then
      ctx = ctx + 1
    end
    j = j + 1
  end
  return { ctx = ctx, add = add, del = del, next = j - 1 }
end

--- Recalculate @@ hunk counts from the actual body lines.
--- @param buf integer
--- @return boolean changed
local function recalc(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local changed = false
  local i = 0
  while i < #lines do
    local header = parse_hunk_header(lines[i + 1])
    if header then
      local c = count_hunk(lines, i)
      header.ocount = c.ctx + c.del
      header.ncount = c.ctx + c.add
      local new = format_hunk(header)
      if new ~= lines[i + 1] then
        vim.api.nvim_buf_set_lines(buf, i, i + 1, false, { new })
        changed = true
      end
      i = c.next
    else
      i = i + 1
    end
  end
  return changed
end

local function mk(lnum, col, message, severity)
  return { lnum = lnum, col = col, severity = severity, message = message }
end

--- Validate diff structure; report via vim.diagnostic.
--- @param buf integer
--- @return integer n_diagnostics
local function validate(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local diags = {}
  local i = 0
  while i < #lines do
    local header = parse_hunk_header(lines[i + 1])
    if header then
      local c = count_hunk(lines, i)
      local old_actual, new_actual = c.ctx + c.del, c.ctx + c.add
      if old_actual ~= header.ocount then
        table.insert(diags, mk(i, 0, string.format("old count is %d, hunk declares %d", old_actual, header.ocount),
          vim.diagnostic.severity.WARN))
      end
      if new_actual ~= header.ncount then
        table.insert(diags, mk(i, 0, string.format("new count is %d, hunk declares %d", new_actual, header.ncount),
          vim.diagnostic.severity.WARN))
      end
      i = c.next
    else
      if is_body(lines[i + 1]) then
        table.insert(diags, mk(i, 0, "hunk body line outside of a hunk header", vim.diagnostic.severity.ERROR))
      end
      i = i + 1
    end
  end
  vim.diagnostic.set(diag_ns, buf, diags)
  return #diags
end

--- Detect the target file/lang of a diff by scanning +++ lines.
local function detect_target(lines)
  local lang, path, count
  for _, line in ipairs(lines) do
    local p = line:match("^%+%+%+%s+(.*)$")
    if p then
      count = (count or 0) + 1
      if not path then
        path = p:gsub("^[ab]/", "")
        if path ~= "/dev/null" then
          lang = vim.filetype.match({ filename = path }) or path:match("%.(%w+)$")
        end
      end
    end
  end
  if count ~= 1 then
    return nil, nil
  end
  return lang, path
end

--- Highlight code inside +/context lines by parsing the reconstructed
--- target file with treesitter and copying highlights as extmarks.
--- @param buf integer
local function highlight(buf)
  if not opts.hl_code then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local lang, _ = detect_target(lines)
  if not lang then
    return
  end

  local content = {}
  local map = {}
  for i, line in ipairs(lines) do
    if not is_file_header(line) then
      local c = line:sub(1, 1)
      if c == " " or c == "+" then
        table.insert(content, line:sub(2))
        map[#content - 1] = i - 1
      end
    end
  end
  if #content == 0 then
    return
  end

  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, content)
  local ok, parser = pcall(vim.treesitter.get_parser, scratch, lang)
  if not ok then
    pcall(vim.api.nvim_buf_delete, scratch, { force = true })
    return
  end
  local ok_parse, trees = pcall(parser.parse, parser)
  local q = vim.treesitter.query.get(lang, "highlights")
  if not ok_parse or not q or not trees or not trees[1] then
    pcall(vim.api.nvim_buf_delete, scratch, { force = true })
    return
  end

  local tree = trees[1]

  for id, node, _, _ in q:iter_captures(tree:root(), scratch, 0, -1) do
    local name = q.captures[id]
    if name and not vim.startswith(name, "_") then
      local sr, sc, er, ec = node:range()
      local start_row, end_row = map[sr], map[er]
      if start_row and end_row then
        vim.api.nvim_buf_set_extmark(buf, hl_ns, start_row, sc + 1, {
          end_row = end_row,
          end_col = ec + 1,
          hl_group = opts.hl_group(name, lang),
          priority = 200,
        })
      end
    end
  end
  pcall(vim.api.nvim_buf_delete, scratch, { force = true })
end

--- o / O on + or - lines: insert a new line with the same prefix and indent.
--- @param above boolean
local function open_line(above)
  local line = vim.api.nvim_get_current_line()
  if is_file_header(line) then
    vim.api.nvim_feedkeys(above and "O" or "o", "n", false)
    return
  end
  local prefix = line:sub(1, 1)
  if prefix ~= "+" and prefix ~= "-" then
    vim.api.nvim_feedkeys(above and "O" or "o", "n", false)
    return
  end
  local indent = line:sub(2):match("^%s*") or ""
  local lnum = vim.api.nvim_win_get_cursor(0)[1] - 1
  local pos = above and lnum or (lnum + 1)
  vim.api.nvim_buf_set_lines(0, pos, pos, false, { prefix .. indent })
  vim.api.nvim_win_set_cursor(0, { pos + 1, #indent + 1 })
  vim.api.nvim_feedkeys("a", "n", false)
end

local function buf_path(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name ~= "" then
    return name
  end
  return (vim.fn.fnamemodify(vim.fn.getcwd(), ":p") .. (vim.bo[buf].file or ""))
end

local function find_root(bufname)
  local dir = bufname ~= "" and vim.fn.fnamemodify(bufname, ":h") or vim.fn.getcwd()
  local git = vim.fs.find(".git", { upward = true, path = dir })[1]
  if git then
    return vim.fn.fnamemodify(git, ":h")
  end
  local cwd_git = vim.fs.find(".git", { upward = true, path = vim.fn.getcwd() })[1]
  if cwd_git then
    return vim.fn.fnamemodify(cwd_git, ":h")
  end
  return vim.fn.getcwd()
end

local function apply_current()
  local buf = vim.api.nvim_get_current_buf()
  recalc(buf)
  local path = buf_path(buf)
  local root = find_root(path)
  local ok = pcall(vim.system, { "git", "apply", "--recount", path }, { cwd = root, text = true }, function(out)
    vim.schedule(function()
      if out.code == 0 then
        vim.notify("DiffApply: applied", vim.log.levels.INFO)
      else
        vim.notify("DiffApply failed:\n" .. (out.stderr or "")
          .. "\nHint: run nvim from inside the git repo, or place the .diff inside it.",
          vim.log.levels.ERROR)
      end
    end)
  end)
  if not ok then
    vim.notify("DiffApply: git not available", vim.log.levels.ERROR)
  end
end

local function show_current()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local lang, path = detect_target(lines)
  if not path then
    vim.notify("DiffShow: no target file in diff", vim.log.levels.WARN)
    return
  end
  local root = find_root(buf_path(buf))
  local full = vim.fs.joinpath(root, path)
  if vim.fn.filereadable(full) == 1 then
    vim.cmd("vsplit " .. vim.fn.fnameescape(full))
    return
  end
  vim.system({ "git", "show", "HEAD:" .. path }, { cwd = root, text = true }, function(out)
    vim.schedule(function()
      if out.code ~= 0 or out.stdout == "" then
        vim.notify("DiffShow: file not in worktree and git show failed:\n" .. (out.stderr or ""),
          vim.log.levels.ERROR)
        return
      end
      local b = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.split(out.stdout, "\n", { plain = true }))
      if lang then
        vim.bo[b].filetype = lang
      end
      vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), b)
    end)
  end)
end

local function setup_buffer(buf)
  vim.keymap.set("n", "o", function()
    open_line(false)
  end, { buffer = buf, desc = "diffedit: open prefixed line below" })
  vim.keymap.set("n", "O", function()
    open_line(true)
  end, { buffer = buf, desc = "diffedit: open prefixed line above" })
  vim.api.nvim_create_autocmd("BufWritePre", {
    buffer = buf,
    callback = function()
      recalc(buf)
      validate(buf)
      highlight(buf)
    end,
  })
  validate(buf)
  highlight(buf)
end

function M.setup(user_opts)
  opts = vim.tbl_deep_extend("force", {}, defaults, user_opts or {})
  vim.api.nvim_create_user_command("DiffRecalc", function()
    recalc(vim.api.nvim_get_current_buf())
  end, {})
  vim.api.nvim_create_user_command("DiffCheck", function()
    local n = validate(vim.api.nvim_get_current_buf())
    if n == 0 then
      vim.notify("DiffCheck: OK", vim.log.levels.INFO)
    end
  end, {})
  vim.api.nvim_create_user_command("DiffApply", apply_current, {})
  vim.api.nvim_create_user_command("DiffShow", show_current, {})
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "diff",
    callback = function(args)
      setup_buffer(args.buf)
    end,
  })
end

M._recalc = recalc
M._validate = validate
M._highlight = highlight
M._open_line = open_line
M._parse_hunk_header = parse_hunk_header

return M
