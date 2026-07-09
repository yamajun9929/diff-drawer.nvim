local M = {}

local defaults = {
  git_executable = "git",
  snacks = {},
}

local state = {
  config = vim.deepcopy(defaults),
}

local function ui()
  return require("diff_drawer.snacks")
end

function M.setup(opts)
  state.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  require("diff_drawer.git").setup(state.config)
  ui().setup(state.config)
end

function M.open(opts)
  return ui().open(opts)
end

function M.toggle(opts)
  return ui().toggle(opts)
end

function M.close()
  return ui().close()
end

function M.focus()
  return ui().focus()
end

function M.refresh()
  return ui().refresh()
end

function M.stage_all()
  return ui().stage_all()
end

function M.unstage_all()
  return ui().unstage_all()
end

function M.toggle_layout()
  return ui().toggle_layout()
end

M._state = state

return M
