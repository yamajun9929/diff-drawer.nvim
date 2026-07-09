local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:append(plugin)

local git = require("diff_drawer.git")

local function run(cwd, args)
  local result = vim.system(args, { cwd = cwd, text = true }):wait()
  assert(result.code == 0, table.concat(args, " ") .. "\n" .. (result.stderr or ""))
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")

run(dir, { "git", "init" })
vim.fn.writefile({ "one" }, dir .. "/a.txt")
run(dir, { "git", "add", "a.txt" })
run(dir, { "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "init" })

vim.fn.writefile({ "one", "two" }, dir .. "/a.txt")
vim.fn.writefile({ "new" }, dir .. "/b.txt")
run(dir, { "git", "add", "b.txt" })

local status = assert(git.status(dir))
assert(#status.changes == 1, "expected one unstaged change")
assert(status.changes[1].path == "a.txt", "expected a.txt in changes")
assert(status.changes[1].status == "M", "expected modified status")
assert(#status.staged == 1, "expected one staged change")
assert(status.staged[1].path == "b.txt", "expected b.txt in staged")
assert(status.staged[1].status == "A", "expected added status")

assert(git.stage(dir, "a.txt"))
status = assert(git.status(dir))
assert(#status.changes == 0, "expected no unstaged changes after stage")
assert(#status.staged == 2, "expected two staged files after stage")

assert(git.unstage(dir, "a.txt"))
status = assert(git.status(dir))
assert(#status.changes == 1, "expected a.txt to return to changes")
assert(status.changes[1].path == "a.txt", "expected a.txt in changes after unstage")

assert(git.discard(dir, status.changes[1]))
status = assert(git.status(dir))
assert(#status.changes == 0, "expected no unstaged changes after discard")
assert(#status.staged == 1, "expected b.txt to remain staged")

assert(git.unstage_all(dir))
status = assert(git.status(dir))
assert(#status.staged == 0, "expected no staged changes after unstage all")
assert(#status.changes == 1, "expected b.txt to become untracked")
assert(status.changes[1].path == "b.txt", "expected b.txt in changes")
assert(status.changes[1].untracked, "expected b.txt to be untracked")

assert(git.discard(dir, status.changes[1]))
status = assert(git.status(dir))
assert(#status.changes == 0, "expected clean changes after untracked discard")
assert(#status.staged == 0, "expected clean staged after untracked discard")

vim.fn.writefile({ "rename" }, dir .. "/old name.txt")
run(dir, { "git", "add", "old name.txt" })
run(dir, { "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "rename base" })
run(dir, { "git", "mv", "old name.txt", "new name.txt" })

local combined = assert(git.status_combined(dir))
assert(#combined == 1, "expected one rename entry")
assert(combined[1].status:sub(1, 1) == "R", "expected staged rename")
assert(combined[1].path == "new name.txt", "expected rename target path")
assert(combined[1].orig_path == "old name.txt", "expected rename source path")
assert(git.unstage(dir, combined[1].path, combined[1].orig_path))

combined = assert(git.status_combined(dir))
local seen = {}
for _, entry in ipairs(combined) do
  seen[entry.path] = entry
end
assert(seen["old name.txt"] and seen["old name.txt"].unstaged, "expected source delete to be unstaged")
assert(seen["new name.txt"] and seen["new name.txt"].untracked, "expected target to become untracked")

vim.fn.delete(dir, "rf")
print("diff-drawer smoke ok")
