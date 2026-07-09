local git = require("diff_drawer.git")
local uv = vim.uv or vim.loop

local M = {}

local state = {
  pickers = setmetatable({}, { __mode = "k" }),
  config = {},
}

local function is_valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function is_valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function notify(message, level)
  if _G.Snacks and Snacks.notify then
    return Snacks.notify(message, { level = level or vim.log.levels.INFO, title = "Diff Drawer" })
  end
  vim.notify(message, level or vim.log.levels.INFO, { title = "Diff Drawer" })
end

local function snackspicker()
  if not (_G.Snacks and Snacks.picker) then
    error("diff-drawer.nvim needs snacks.nvim for the explorer UI")
  end
  return Snacks.picker
end

local function active_pickers()
  return snackspicker().get({ source = "diff_drawer", tab = false })
end

local function close_snacks_source(source)
  for _, picker in ipairs(snackspicker().get({ source = source, tab = false })) do
    pcall(picker.close, picker)
  end
end

local function selected_entries(picker, item)
  local entries = {}
  local seen = {}

  local function add(entry)
    if entry and not seen[entry.path] then
      seen[entry.path] = true
      entries[#entries + 1] = entry
    end
  end

  local function add_item(it)
    if not it then
      return
    end

    if it.entry then
      add(it.entry)
    elseif it.entries then
      for _, entry in ipairs(it.entries) do
        add(entry)
      end
    end
  end

  local selected = picker:selected()
  if #selected == 0 and item then
    selected = { item }
  elseif #selected == 0 then
    selected = { picker:current() }
  end

  for _, it in ipairs(selected) do
    add_item(it)
  end

  return entries
end

local function refresh(picker)
  picker.list:set_selected()
  picker.list:set_target()
  picker:refresh()
  vim.cmd.checktime()
end

local function run_git(repo, args, callback)
  local ok, _out, err = git.run(repo, args)
  if not ok then
    notify(err ~= "" and err or "git command failed", vim.log.levels.ERROR)
    return
  end
  if callback then
    callback()
  end
end

local function repo_for_picker(picker)
  return picker:cwd()
end

local function default_cwd()
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= "" then
    if vim.fn.filereadable(name) == 1 then
      return vim.fs.dirname(name)
    end
    if vim.fn.isdirectory(name) == 1 then
      return name
    end
  end
  return vim.fn.getcwd()
end

local function stage_entries(picker, entries)
  if #entries == 0 then
    return
  end

  local repo = repo_for_picker(picker)
  local args = { "add", "--" }
  for _, entry in ipairs(entries) do
    args[#args + 1] = entry.path
  end

  run_git(repo, args, function()
    refresh(picker)
  end)
end

local function unstage_entries(picker, entries)
  entries = vim.tbl_filter(function(entry)
    return entry.staged
  end, entries)

  if #entries == 0 then
    notify("ステージ済みの変更はありません", vim.log.levels.WARN)
    return
  end

  local repo = repo_for_picker(picker)
  local args = git.has_head(repo) and { "restore", "--staged", "--" } or { "rm", "--cached", "-r", "--" }
  local seen = {}

  local function add_path(path)
    if path and not seen[path] then
      seen[path] = true
      args[#args + 1] = path
    end
  end

  for _, entry in ipairs(entries) do
    add_path(entry.path)
    if entry.status:sub(1, 1) == "R" then
      add_path(entry.orig_path)
    end
  end

  run_git(repo, args, function()
    refresh(picker)
  end)
end

local function discard_entries(picker, entries)
  entries = vim.tbl_filter(function(entry)
    return entry.unstaged
  end, entries)

  if #entries == 0 then
    notify("取り消せる未ステージ変更はありません", vim.log.levels.WARN)
    return
  end

  local label = #entries == 1 and entries[1].path or (#entries .. " files")
  Snacks.picker.util.confirm("Discard changes to " .. label .. "?", function()
    local repo = repo_for_picker(picker)
    for _, entry in ipairs(entries) do
      local ok, _out, err = git.discard(repo, entry)
      if not ok then
        notify(err ~= "" and err or "git command failed", vim.log.levels.ERROR)
        return
      end
    end
    refresh(picker)
  end)
end

local function state_for(picker)
  if not state.pickers[picker] then
    state.pickers[picker] = {
      closed = {},
      diff_wins = {},
      diff_bufs = {},
      diff_keymaps = {},
    }
  end
  return state.pickers[picker]
end

local function focus_list(picker)
  if not picker or picker.closed then
    return false
  end

  if picker.layout and picker.layout.show then
    pcall(picker.layout.show, picker.layout)
  end

  if picker.focus then
    picker:focus("list", { show = true })
    if picker.current_win and picker:current_win() == "list" then
      return true
    end
  end

  if picker.list and picker.list.win and picker.list.win.focus then
    picker.list.win:focus()
    if not picker.current_win or picker:current_win() == "list" then
      return true
    end
  end

  return picker.current_win and picker:current_win() == "list" or false
end

local function has_keymap(maps, lhs)
  for _, map in ipairs(maps) do
    if map.lhs == lhs then
      return true
    end
  end
  return false
end

local clear_edit_diff
local ensure_edit_window
local select_item

local function set_diff_back_key(picker, buf)
  if not is_valid_buf(buf) then
    return
  end

  local st = state_for(picker)
  st.diff_keymaps = st.diff_keymaps or {}

  if st.diff_keymaps[buf] or has_keymap(vim.api.nvim_get_keymap("n"), "<BS>") then
    return
  end

  if has_keymap(vim.api.nvim_buf_get_keymap(buf, "n"), "<BS>") then
    return
  end

  vim.keymap.set("n", "<BS>", function()
    clear_edit_diff(picker)
    focus_list(picker)
  end, { buffer = buf, silent = true, desc = "Close Diff Drawer diff" })

  st.diff_keymaps[buf] = true
end

clear_edit_diff = function(picker)
  local st = state_for(picker)

  for _, win in ipairs(st.diff_wins or {}) do
    if is_valid_win(win) then
      pcall(vim.api.nvim_win_call, win, function()
        vim.cmd("diffoff!")
      end)
    end
  end

  if is_valid_win(st.diff_wins and st.diff_wins[1]) then
    pcall(vim.api.nvim_win_close, st.diff_wins[1], true)
  end

  for _, buf in ipairs(st.diff_bufs or {}) do
    if is_valid_buf(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  for buf in pairs(st.diff_keymaps or {}) do
    if is_valid_buf(buf) then
      pcall(vim.keymap.del, "n", "<BS>", { buffer = buf })
    end
  end

  st.diff_wins = {}
  st.diff_bufs = {}
  st.diff_keymaps = {}
end

local function split_path(path)
  local parts = {}
  for part in path:gmatch("[^/]+") do
    parts[#parts + 1] = part
  end
  return parts
end

local function status_rank(status)
  if status:find("^[MADRCU]") then
    return 1
  elseif status:find("[MADRCU]$") then
    return 2
  elseif status == "??" then
    return 3
  end
  return 4
end

local function aggregate_status(current, status)
  if not current then
    return status
  end
  return status_rank(status) < status_rank(current) and status or current
end

local function make_node(name, path, parent, dir)
  return {
    name = name,
    file = path,
    text = path,
    parent = parent,
    dir = dir,
    open = dir and true or nil,
    type = dir and "directory" or "file",
    entries = {},
  }
end

local function build_tree(repo, entries)
  local root = make_node(vim.fn.fnamemodify(repo, ":t"), "", nil, true)
  local nodes = { [""] = root }

  local function ensure_dir(parent, name)
    local path = parent.file == "" and name or (parent.file .. "/" .. name)
    if not nodes[path] then
      nodes[path] = make_node(name, path, parent, true)
      parent.children = parent.children or {}
      parent.children[#parent.children + 1] = nodes[path]
    end
    return nodes[path]
  end

  for _, entry in ipairs(entries) do
    local node = root
    local parts = split_path(entry.path)

    for i = 1, #parts - 1 do
      node = ensure_dir(node, parts[i])
      node.status = aggregate_status(node.status, entry.status)
      node.entries[#node.entries + 1] = entry
    end

    local file = make_node(parts[#parts] or entry.path, entry.path, node, false)
    file.entry = entry
    file.status = entry.status
    file.rename = entry.orig_path
    file.cwd = repo
    file.children = nil
    node.children = node.children or {}
    node.children[#node.children + 1] = file
    node.entries[#node.entries + 1] = entry
  end

  return root
end

local function sort_children(children)
  table.sort(children, function(a, b)
    if a.dir ~= b.dir then
      return a.dir
    end
    return a.name < b.name
  end)
end

local function emit_tree(node, picker_state, cb)
  local children = node.children or {}
  sort_children(children)

  for index, child in ipairs(children) do
    child.last = index == #children
    child.cwd = child.cwd or node.cwd
    cb(child)

    if child.dir and not picker_state.closed[child.file] then
      emit_tree(child, picker_state, cb)
    end
  end
end

local function status_async(repo, async)
  if not async then
    return git.status_combined(repo)
  end

  local stdout = assert(uv.new_pipe())
  local chunks = {}
  local code = nil
  local exited = false
  local eof = false
  local spawn_args = {
    "-C",
    repo,
    "-c",
    "core.quotepath=false",
    "status",
    "--porcelain=v1",
    "-z",
    "--untracked-files=all",
  }

  local function done()
    if exited and eof then
      async:resume()
    end
  end

  local handle
  handle = uv.spawn(git.executable or "git", {
    args = spawn_args,
    stdio = { nil, stdout, nil },
    cwd = repo,
    hide = true,
  }, function(exit_code)
    code = exit_code
    exited = true
    if handle and not handle:is_closing() then
      handle:close()
    end
    done()
  end)

  if not handle then
    stdout:close()
    return nil, "failed to spawn git"
  end

  stdout:read_start(function(err, data)
    if err then
      chunks[#chunks + 1] = ""
    elseif data then
      chunks[#chunks + 1] = data
    else
      eof = true
      stdout:read_stop()
      if not stdout:is_closing() then
        stdout:close()
      end
      done()
    end
  end)

  async:on("abort", function()
    if not stdout:is_closing() then
      stdout:close()
    end
    if handle and not handle:is_closing() then
      handle:kill("sigterm")
    end
  end)

  async:suspend()

  if code ~= 0 then
    return nil, "git status failed"
  end

  return git.parse_status_combined(table.concat(chunks))
end

local function finder(opts, ctx)
  local repo, err = git.root(opts.cwd or default_cwd())
  if not repo then
    notify(err, vim.log.levels.ERROR)
    return function() end
  end

  ctx.picker:set_cwd(repo)

  return function(cb)
    local entries, status_err = status_async(repo, ctx.async)
    if not entries then
      notify(status_err, vim.log.levels.ERROR)
      return
    end

    local root = build_tree(repo, entries)
    root.cwd = repo
    emit_tree(root, state_for(ctx.picker), cb)
  end
end

local function preview(ctx)
  local item = ctx.item
  if not item or item.dir then
    ctx.preview:reset()
    if item and item.entries then
      local lines = { item.file == "" and ctx.picker:cwd() or item.file, "" }
      for _, entry in ipairs(item.entries) do
        lines[#lines + 1] = entry.status .. " " .. entry.path
      end
      ctx.preview:set_lines(lines)
    end
    return true
  end
  return Snacks.picker.preview.git_status(ctx)
end

local function open_file(picker, item, action)
  item = item or picker:current()
  if not item or item.dir then
    return
  end
  clear_edit_diff(picker)
  select_item(picker, item)
  if not ensure_edit_window(picker) then
    notify("ファイルを開ける編集ウィンドウがありません", vim.log.levels.ERROR)
    return
  end
  Snacks.picker.actions.jump(picker, item, action or { cmd = "edit" })
end

select_item = function(picker, item)
  if not (picker and picker.list and item) then
    return
  end

  for index = 1, picker.list:count() do
    local candidate = picker.list:get(index)
    local same_entry = candidate and candidate.entry and item.entry and candidate.entry.path == item.entry.path
    if candidate == item or same_entry then
      picker.list.cursor = index
      if picker.list.win and picker.list.win:win_valid() then
        local row = picker.list:idx2row(index)
        local height = picker.list.state and picker.list.state.height
          or vim.api.nvim_win_get_height(picker.list.win.win)
        if row < 1 or row > height then
          picker.list.top = index
          picker.list.dirty = true
          picker.list:render()
          row = picker.list:idx2row(index)
        end
        pcall(vim.api.nvim_win_set_cursor, picker.list.win.win, { row, 0 })
      end
      return
    end
  end
end

local function show_preview(picker, item)
  item = item or picker:current()
  if not item or item.dir then
    return
  end

  clear_edit_diff(picker)
  select_item(picker, item)

  local function render()
    if not picker or picker.closed then
      return
    end

    select_item(picker, item)

    if picker.preview then
      if picker.preview.update then
        pcall(picker.preview.update, picker.preview, picker)
      end
      if picker.preview.win and picker.preview.win:valid() then
        local prev = picker.preview.item
        local buf = picker.preview.win.buf
        picker.preview.item = item
        picker.preview.filter = picker:filter()
        picker.preview.pos = item.pos
        if picker.preview.spinner then
          picker.preview:spinner(false)
        end

        local ok, err = pcall(
          preview,
          setmetatable({
            preview = picker.preview,
            item = item,
            prev = prev,
            picker = picker,
          }, {
            __index = function(_, key)
              if key == "buf" then
                return picker.preview.win.buf
              elseif key == "win" then
                return picker.preview.win.win
              end
            end,
          })
        )
        if not ok and picker.preview.notify then
          picker.preview:notify(err, "error")
        end
        if picker.preview.win.buf ~= buf and picker.preview.clear then
          picker.preview:clear(buf)
        end
        select_item(picker, item)
        return true
      end
    end

    if picker.show_preview then
      pcall(picker.show_preview, picker)
      return true
    end
  end

  if render() then
    vim.schedule(function()
      render()
    end)
    return
  end
end

local function lines_from_string(value)
  if not value or value == "" then
    return { "" }
  end
  value = value:gsub("\r\n", "\n")
  if value:sub(-1) == "\n" then
    value = value:sub(1, -2)
  end
  return vim.split(value, "\n", { plain = true })
end

local function scratch_buffer(picker, name, file, lines)
  local st = state_for(picker)
  local buf = vim.api.nvim_create_buf(false, true)
  st.diff_bufs[#st.diff_bufs + 1] = buf

  vim.api.nvim_buf_set_name(buf, "diff-drawer://" .. name .. "/" .. file)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = vim.filetype.match({ filename = file }) or ""
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true

  return buf
end

local function baseline_buffer(picker, item)
  local repo = repo_for_picker(picker)
  local entry = item.entry

  if entry.untracked then
    return scratch_buffer(picker, "empty", entry.path, { "" })
  end

  local x = entry.status:sub(1, 1)
  local y = entry.status:sub(2, 2)
  local spec
  local label

  if y ~= " " then
    spec = ":" .. entry.path
    label = "index"
  else
    spec = "HEAD:" .. (entry.orig_path or entry.path)
    label = "HEAD"
  end

  local content = label == "HEAD" and x == "A" and "" or git.show(repo, spec) or ""
  return scratch_buffer(picker, label, entry.path, lines_from_string(content))
end

local function worktree_buffer(picker, item)
  local entry = item.entry
  local path = repo_for_picker(picker) .. "/" .. entry.path

  if vim.fn.filereadable(path) ~= 1 then
    return scratch_buffer(picker, "deleted", entry.path, { "" }), false
  end

  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  return buf, true
end

local function picker_window_ids(picker)
  local ids = {}

  local function add(win)
    if type(win) == "number" and is_valid_win(win) then
      ids[win] = true
    end
  end

  for _, name in ipairs({ "input", "list" }) do
    local part = picker[name]
    if part and part.win then
      add(part.win.win)
      if part.win.opts then
        add(part.win.opts.win)
      end
    end
  end

  if picker.layout and picker.layout.wins then
    for _, name in ipairs({ "input", "list" }) do
      local win = picker.layout.wins[name]
      if win then
        add(win.win)
        if win.opts then
          add(win.opts.win)
        end
      end
    end
  end

  return ids
end

local function main_window(picker)
  local skip = picker_window_ids(picker)

  if is_valid_win(picker.main) and not skip[picker.main] then
    return picker.main
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_valid_win(win) and not skip[win] and vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
end

ensure_edit_window = function(picker)
  if not picker or picker.closed then
    return nil
  end

  if picker.set_layout then
    pcall(picker.set_layout, picker, "sidebar")
  end
  if picker._main and picker._main.update then
    pcall(picker._main.update, picker._main)
  end

  local win = main_window(picker)
  if win then
    picker.main = win
    return win
  end

  local list_win = picker.list and picker.list.win and picker.list.win.win
  if not is_valid_win(list_win) then
    return nil
  end

  vim.api.nvim_set_current_win(list_win)
  vim.cmd("rightbelow vertical new")
  win = vim.api.nvim_get_current_win()
  vim.w[win].snacks_main = true
  picker.main = win
  vim.cmd("lcd " .. vim.fn.fnameescape(repo_for_picker(picker)))
  focus_list(picker)
  return win
end

local function open_diff(picker, item)
  item = item or picker:current()
  if not item or item.dir then
    return
  end

  local repo = repo_for_picker(picker)
  local entry = item.entry
  local st = state_for(picker)
  select_item(picker, item)
  local base_win = is_valid_win(st.diff_wins[2]) and st.diff_wins[2] or ensure_edit_window(picker)

  if not base_win then
    notify("差分を開ける編集ウィンドウがありません", vim.log.levels.ERROR)
    return
  end

  clear_edit_diff(picker)

  local left_buf = baseline_buffer(picker, item)
  local right_buf, editable = worktree_buffer(picker, item)

  vim.api.nvim_set_current_win(base_win)
  vim.api.nvim_win_set_buf(base_win, left_buf)
  local left_win = base_win

  vim.cmd("rightbelow vertical split")
  local right_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(right_win, right_buf)

  st.diff_wins = { left_win, right_win }
  picker.main = right_win
  set_diff_back_key(picker, left_buf)
  set_diff_back_key(picker, right_buf)

  for _, win in ipairs(st.diff_wins) do
    vim.api.nvim_win_call(win, function()
      vim.wo.wrap = false
      vim.cmd("diffthis")
    end)
  end

  if editable then
    vim.api.nvim_set_current_win(right_win)
  else
    vim.api.nvim_set_current_win(left_win)
    notify("削除済みファイルなので、右ペインは編集できません: " .. entry.path, vim.log.levels.WARN)
  end

  vim.cmd("lcd " .. vim.fn.fnameescape(repo))
end

local function toggle_dir(picker, item)
  item = item or picker:current()
  if not item or not item.dir then
    return
  end
  local st = state_for(picker)
  st.closed[item.file] = not st.closed[item.file] or nil
  picker:refresh()
end

local function close_dir(picker, item)
  item = item or picker:current()
  if not item then
    return
  end
  local target = item.dir and item.file or (item.parent and item.parent.file)
  if not target then
    return
  end
  state_for(picker).closed[target] = true
  picker:refresh()
end

local function preview_or_toggle(picker, item)
  item = item or picker:current()
  if item and item.dir then
    return toggle_dir(picker, item)
  end
  return show_preview(picker, item)
end

local actions = {
  scm_preview = preview_or_toggle,
  scm_confirm = preview_or_toggle,
  scm_open_diff = open_diff,
  scm_open_file = open_file,
  scm_toggle_dir = toggle_dir,
  scm_close_dir = close_dir,
  scm_stage = function(picker, item)
    stage_entries(picker, selected_entries(picker, item))
  end,
  scm_unstage = function(picker, item)
    unstage_entries(picker, selected_entries(picker, item))
  end,
  scm_discard = function(picker, item)
    discard_entries(picker, selected_entries(picker, item))
  end,
  scm_stage_all = function(picker)
    run_git(repo_for_picker(picker), { "add", "-A" }, function()
      refresh(picker)
    end)
  end,
  scm_unstage_all = function(picker)
    local repo = repo_for_picker(picker)
    local args = git.has_head(repo) and { "restore", "--staged", "." } or { "rm", "--cached", "-r", "." }
    run_git(repo, args, function()
      refresh(picker)
    end)
  end,
  scm_refresh = function(picker)
    refresh(picker)
  end,
}

function M.setup(config)
  state.config = config or {}
end

function M.open(opts)
  close_snacks_source("explorer")

  local existing = active_pickers()[1]
  if existing then
    return existing
  end

  opts = vim.tbl_deep_extend("force", state.config.snacks or {}, opts or {})

  return snackspicker()({
    source = "diff_drawer",
    title = opts.title or "Git Changes",
    cwd = opts.cwd or default_cwd(),
    finder = finder,
    format = "file",
    preview = preview,
    focus = "list",
    auto_close = false,
    show_empty = true,
    matcher = { sort_empty = false, fuzzy = false },
    sort = { fields = { "idx" } },
    jump = { close = false, reuse_win = true },
    layout = opts.layout or { preset = "sidebar" },
    formatters = {
      file = { filename_only = true },
      severity = { pos = "right" },
    },
    actions = actions,
    confirm = "scm_preview",
    win = {
      list = {
        keys = {
          ["<CR>"] = { "scm_preview", desc = "Preview diff" },
          ["l"] = { "scm_open_diff", desc = "Open editable diff" },
          ["o"] = { "scm_open_file", desc = "Open working-tree file" },
          ["p"] = { "focus_preview", desc = "Focus preview" },
          ["<S-CR>"] = { "scm_open_file", desc = "Open working-tree file" },
          ["h"] = "scm_close_dir",
          ["s"] = "scm_stage",
          ["u"] = "scm_unstage",
          ["x"] = "scm_discard",
          ["S"] = "scm_stage_all",
          ["U"] = "scm_unstage_all",
          ["r"] = "scm_refresh",
          ["<Tab>"] = "scm_stage",
        },
      },
      input = {
        keys = {
          ["<Tab>"] = { "scm_stage", mode = { "n", "i" } },
          ["<c-r>"] = { "scm_refresh", mode = { "n", "i" }, nowait = true },
        },
      },
      preview = {
        keys = {
          ["<BS>"] = { "focus_list", desc = "Focus list" },
          ["h"] = { "focus_list", desc = "Focus list" },
        },
      },
    },
  })
end

function M.toggle(opts)
  local existing = active_pickers()[1]
  if existing then
    clear_edit_diff(existing)
    existing:close()
    return
  end
  return M.open(opts)
end

function M.close()
  for _, picker in ipairs(active_pickers()) do
    clear_edit_diff(picker)
    picker:close()
  end
end

function M.focus()
  return focus_list(active_pickers()[1])
end

function M.refresh()
  local picker = active_pickers()[1]
  if picker then
    refresh(picker)
  end
end

function M.stage_all()
  local picker = active_pickers()[1]
  local repo, err = picker and repo_for_picker(picker) or git.root(default_cwd())
  if not repo then
    return notify(err, vim.log.levels.ERROR)
  end
  run_git(repo, { "add", "-A" }, M.refresh)
end

function M.unstage_all()
  local picker = active_pickers()[1]
  local repo, err = picker and repo_for_picker(picker) or git.root(default_cwd())
  if not repo then
    return notify(err, vim.log.levels.ERROR)
  end
  local args = git.has_head(repo) and { "restore", "--staged", "." } or { "rm", "--cached", "-r", "." }
  run_git(repo, args, M.refresh)
end

function M.toggle_layout()
  local picker = active_pickers()[1]
  if not picker then
    return M.open()
  end
  picker:set_layout(picker.layout.split and "default" or "sidebar")
end

M._state = state

return M
