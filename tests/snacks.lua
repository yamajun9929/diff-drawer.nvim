local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local snacks = vim.env.SNACKS_NVIM_PATH or vim.fn.expand("~/.local/share/nvim/lazy/snacks.nvim")

if vim.fn.isdirectory(snacks) ~= 1 then
  print("snacks integration skipped")
  return
end

vim.opt.runtimepath:prepend(snacks)
vim.opt.runtimepath:append(plugin)
require("snacks").setup({ picker = { enabled = true } })

local drawer = require("diff_drawer")
local git = require("diff_drawer.git")

local function run(cwd, args)
  local result = vim.system(args, { cwd = cwd, text = true }):wait()
  assert(result.code == 0, table.concat(args, " ") .. "\n" .. (result.stderr or ""))
end

local function find_item(picker, path)
  for index, item in ipairs(picker:items()) do
    if item.entry and item.entry.path == path then
      return item, index
    end
  end
end

local function select_index(picker, index)
  picker.list.cursor = index
end

local function has_buffer_key(buf, lhs)
  for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if keymap.lhs == lhs then
      return true
    end
  end
  return false
end

local function wipe_buffers_under(root)
  local roots = { root }
  local real = (vim.uv or vim.loop).fs_realpath(root)
  if real and real ~= root then
    roots[#roots + 1] = real
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    for _, candidate in ipairs(roots) do
      local prefix = candidate .. "/"
      if name:sub(1, #prefix) == prefix then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        break
      end
    end
  end
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/a/b", "p")
run(dir, { "git", "init" })
vim.fn.writefile({ "old" }, dir .. "/a/b/x.txt")
run(dir, { "git", "add", "a/b/x.txt" })
run(dir, { "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "init" })
vim.fn.writefile({ "old", "new" }, dir .. "/a/b/x.txt")

vim.cmd.cd(dir)

Snacks.picker({
  source = "explorer",
  items = { { text = "dummy" } },
})
vim.wait(1000, function()
  return #Snacks.picker.get({ source = "explorer", tab = false }) == 1
end)

local picker = assert(drawer.open())
vim.wait(1000, function()
  return #picker:items() >= 3
end)
assert(#Snacks.picker.get({ source = "explorer", tab = false }) == 0, "expected explorer picker to close")
assert(drawer.open() == picker, "expected open to be idempotent")

local items = picker:items()
assert(items[1].dir == true, "expected directory tree item")
assert(items[3].entry and items[3].entry.path == "a/b/x.txt", "expected changed file item")

local before = #items
select_index(picker, 1)
picker:action("scm_confirm")
vim.wait(1000, function()
  local collapsed = picker:items()
  return #collapsed == 1 and collapsed[1].dir and collapsed[1].file == "a"
end)
assert(#picker:items() < before, "expected directory confirm to collapse")

select_index(picker, 1)
picker:action("scm_confirm")
vim.wait(1000, function()
  return find_item(picker, "a/b/x.txt") ~= nil
end)
local file_item, file_index = find_item(picker, "a/b/x.txt")
assert(file_item, "expected changed file item after expand")

select_index(picker, file_index)
picker:action("scm_confirm")
local state = require("diff_drawer.snacks")._state.pickers[picker]
assert(state and #state.diff_wins == 2, "expected editable diff windows")
local left = vim.api.nvim_win_get_buf(state.diff_wins[1])
local right = vim.api.nvim_win_get_buf(state.diff_wins[2])
local left_win = state.diff_wins[1]
assert(vim.api.nvim_buf_get_lines(left, 0, -1, false)[1] == "old", "expected baseline content")
assert(vim.api.nvim_buf_get_name(right):match("a/b/x%.txt$"), "expected right pane to be working-tree file")
assert(vim.bo[right].modifiable == true, "expected right pane to be editable")
assert(has_buffer_key(right, "<BS>"), "expected editable diff to map back to drawer")
vim.api.nvim_set_current_win(state.diff_wins[2])
assert(drawer.focus(), "expected focus call to succeed")
assert(picker:current_win() == "list", "expected focus to return to drawer list")
vim.api.nvim_set_current_win(state.diff_wins[2])
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<BS>", true, false, true), "x", false)
assert(picker:current_win() == "list", "expected backspace to return to drawer list")
assert(#state.diff_wins == 0, "expected backspace to close editable diff windows")
assert(not vim.api.nvim_win_is_valid(left_win), "expected baseline diff window to close")
assert(not has_buffer_key(right, "<BS>"), "expected backspace mapping to be cleaned up")

select_index(picker, file_index)
picker:action("scm_stage")
vim.wait(1000, function()
  local status = git.status_combined(dir)
  return status and status[1] and status[1].staged
end)
assert(git.status_combined(dir)[1].staged, "expected file to be staged")

drawer.close()
assert(not has_buffer_key(right, "<BS>"), "expected diff back mapping to be cleaned up")

vim.fn.writefile({ "staged" }, dir .. "/added.txt")
run(dir, { "git", "add", "added.txt" })
vim.fn.writefile({ "staged", "unstaged" }, dir .. "/added.txt")

picker = assert(drawer.open())
vim.wait(1000, function()
  return find_item(picker, "added.txt") ~= nil
end)

local added_item, added_index = find_item(picker, "added.txt")
assert(added_item, "expected staged added file with unstaged changes")
select_index(picker, added_index)
picker:action("scm_confirm")

state = require("diff_drawer.snacks")._state.pickers[picker]
assert(state and #state.diff_wins == 2, "expected editable diff windows for staged added file")
left = vim.api.nvim_win_get_buf(state.diff_wins[1])
assert(vim.api.nvim_buf_get_lines(left, 0, -1, false)[1] == "staged", "expected index baseline content")

drawer.close()
wipe_buffers_under(dir)
vim.fn.delete(dir, "rf")

local rename_dir = vim.fn.tempname()
vim.fn.mkdir(rename_dir, "p")
run(rename_dir, { "git", "init" })
vim.fn.writefile({ "rename" }, rename_dir .. "/old name.txt")
run(rename_dir, { "git", "add", "old name.txt" })
run(rename_dir, { "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "init" })
run(rename_dir, { "git", "mv", "old name.txt", "new name.txt" })

vim.cmd.cd(rename_dir)
picker = assert(drawer.open())
vim.wait(1000, function()
  return find_item(picker, "new name.txt") ~= nil
end)

local rename_item, rename_index = find_item(picker, "new name.txt")
assert(rename_item and rename_item.entry.orig_path == "old name.txt", "expected rename item")
select_index(picker, rename_index)
picker:action("scm_unstage")

vim.wait(1000, function()
  local entries = git.status_combined(rename_dir) or {}
  local seen = {}
  for _, entry in ipairs(entries) do
    seen[entry.path] = entry
  end
  return seen["old name.txt"] and seen["old name.txt"].unstaged and seen["new name.txt"] and seen["new name.txt"].untracked
end)

local rename_status = git.status_combined(rename_dir) or {}
local rename_seen = {}
for _, entry in ipairs(rename_status) do
  rename_seen[entry.path] = entry
end
assert(rename_seen["old name.txt"] and rename_seen["old name.txt"].unstaged, "expected rename source to be unstaged")
assert(rename_seen["new name.txt"] and rename_seen["new name.txt"].untracked, "expected rename target to be untracked")

drawer.close()
wipe_buffers_under(rename_dir)
vim.fn.delete(rename_dir, "rf")

local buffer_dir = vim.fn.tempname()
local nonrepo_dir = vim.fn.tempname()
vim.fn.mkdir(buffer_dir, "p")
vim.fn.mkdir(nonrepo_dir, "p")
run(buffer_dir, { "git", "init" })
vim.fn.writefile({ "buffer" }, buffer_dir .. "/buffer.txt")
run(buffer_dir, { "git", "add", "buffer.txt" })
run(buffer_dir, { "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "init" })
vim.fn.writefile({ "buffer", "changed" }, buffer_dir .. "/buffer.txt")

vim.cmd.cd(nonrepo_dir)
vim.cmd("edit " .. vim.fn.fnameescape(buffer_dir .. "/buffer.txt"))
picker = assert(drawer.open())
vim.wait(1000, function()
  return find_item(picker, "buffer.txt") ~= nil
end)
assert(find_item(picker, "buffer.txt"), "expected drawer to use current buffer repo")

drawer.close()
wipe_buffers_under(buffer_dir)
vim.fn.delete(buffer_dir, "rf")
vim.fn.delete(nonrepo_dir, "rf")
print("snacks integration ok")
