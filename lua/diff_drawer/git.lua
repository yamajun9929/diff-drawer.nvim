local M = {}

M.executable = "git"

function M.setup(opts)
  M.executable = (opts and opts.git_executable) or M.executable
end

local function git(cwd, args, opts)
  opts = opts or {}
  local cmd = { M.executable }
  if cwd and cwd ~= "" then
    vim.list_extend(cmd, { "-C", cwd })
  end
  vim.list_extend(cmd, args)

  local result = vim.system(cmd, {
    text = opts.text ~= false,
  }):wait()

  local stdout = result.stdout or ""
  local stderr = result.stderr or ""

  if result.code ~= 0 then
    return false, stdout, vim.trim(stderr), result.code
  end

  return true, stdout, stderr, result.code
end

function M.run(repo, args, opts)
  return git(repo, args, opts)
end

function M.root(cwd)
  local ok, out, err = git(cwd, { "rev-parse", "--show-toplevel" })
  if not ok then
    return nil, err ~= "" and err or "not inside a git repository"
  end
  return vim.trim(out)
end

function M.branch(repo)
  local ok, out = git(repo, { "branch", "--show-current" })
  local branch = ok and vim.trim(out) or ""
  if branch ~= "" then
    return branch
  end

  ok, out = git(repo, { "rev-parse", "--short", "HEAD" })
  if ok then
    local head = vim.trim(out)
    if head ~= "" then
      return head
    end
  end

  return "no commits"
end

function M.has_head(repo)
  local ok = git(repo, { "rev-parse", "--verify", "HEAD" })
  return ok
end

local function split_nul(value)
  local parts = {}
  local start = 1

  while true do
    local pos = value:find("\0", start, true)
    if not pos then
      break
    end
    table.insert(parts, value:sub(start, pos - 1))
    start = pos + 1
  end

  if start <= #value then
    table.insert(parts, value:sub(start))
  end

  return parts
end

local function is_unmerged(x, y)
  return x == "U"
    or y == "U"
    or (x == "A" and y == "A")
    or (x == "D" and y == "D")
end

local function section_entry(section, status, path, xy, orig_path)
  return {
    section = section,
    status = status,
    path = path,
    xy = xy,
    orig_path = orig_path,
    untracked = xy == "??",
  }
end

function M.status(repo)
  local ok, out, err = git(repo, {
    "-c",
    "core.quotepath=false",
    "status",
    "--porcelain=v1",
    "-z",
    "--untracked-files=all",
  }, { text = false })

  if not ok then
    return nil, err
  end

  local staged = {}
  local changes = {}
  local parts = split_nul(out)
  local i = 1

  while i <= #parts do
    local record = parts[i]
    if record ~= "" then
      local xy = record:sub(1, 2)
      local x = xy:sub(1, 1)
      local y = xy:sub(2, 2)
      local path = record:sub(4)
      local orig_path = nil

      if x == "R" or x == "C" then
        orig_path = parts[i + 1]
        i = i + 1
      end

      if xy == "??" then
        table.insert(changes, section_entry("changes", "U", path, xy, orig_path))
      elseif xy ~= "!!" then
        if is_unmerged(x, y) then
          table.insert(changes, section_entry("changes", "U", path, xy, orig_path))
        else
          if x ~= " " then
            table.insert(staged, section_entry("staged", x, path, xy, orig_path))
          end
          if y ~= " " then
            table.insert(changes, section_entry("changes", y, path, xy, orig_path))
          end
        end
      end
    end

    i = i + 1
  end

  table.sort(staged, function(a, b)
    return a.path < b.path
  end)
  table.sort(changes, function(a, b)
    return a.path < b.path
  end)

  return {
    staged = staged,
    changes = changes,
  }
end

function M.parse_status_combined(out)
  local items = {}
  local parts = split_nul(out)
  local i = 1

  while i <= #parts do
    local record = parts[i]
    if record ~= "" then
      local xy = record:sub(1, 2)
      local x = xy:sub(1, 1)
      local path = record:sub(4)
      local orig_path = nil

      if x == "R" or x == "C" then
        orig_path = parts[i + 1]
        i = i + 1
      end

      if xy ~= "!!" then
        table.insert(items, {
          status = xy,
          path = path,
          orig_path = orig_path,
          untracked = xy == "??",
          staged = xy:sub(1, 1) ~= " " and xy ~= "??",
          unstaged = xy == "??" or xy:sub(2, 2) ~= " ",
          unmerged = is_unmerged(xy:sub(1, 1), xy:sub(2, 2)),
        })
      end
    end

    i = i + 1
  end

  table.sort(items, function(a, b)
    return a.path < b.path
  end)

  return items
end

function M.status_combined(repo)
  local ok, out, err = git(repo, {
    "-c",
    "core.quotepath=false",
    "status",
    "--porcelain=v1",
    "-z",
    "--untracked-files=all",
  }, { text = false })

  if not ok then
    return nil, err
  end

  return M.parse_status_combined(out)
end

function M.show(repo, spec)
  local ok, out, err = git(repo, { "show", "--textconv", spec }, { text = true })
  if not ok then
    return nil, err
  end
  return out
end

function M.stage(repo, path)
  return git(repo, { "add", "--", path })
end

function M.stage_all(repo)
  return git(repo, { "add", "-A" })
end

function M.unstage(repo, path, orig_path)
  if M.has_head(repo) then
    local args = { "restore", "--staged", "--", path }
    if orig_path then
      args[#args + 1] = orig_path
    end
    return git(repo, args)
  end
  return git(repo, { "rm", "--cached", "-r", "--", path })
end

function M.unstage_all(repo)
  if M.has_head(repo) then
    return git(repo, { "restore", "--staged", "." })
  end
  return git(repo, { "rm", "--cached", "-r", "." })
end

function M.discard(repo, entry)
  if entry.untracked then
    return git(repo, { "clean", "-fd", "--", entry.path })
  end
  return git(repo, { "restore", "--worktree", "--", entry.path })
end

function M.discard_all(repo)
  if M.has_head(repo) then
    local ok, out, err = git(repo, { "restore", "--worktree", "." })
    if not ok then
      return ok, out, err
    end
  end

  return git(repo, { "clean", "-fd", "." })
end

return M
