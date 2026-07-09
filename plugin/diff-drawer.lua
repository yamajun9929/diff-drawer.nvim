if vim.g.loaded_diff_drawer == 1 then
  return
end
vim.g.loaded_diff_drawer = 1

local function drawer()
  return require("diff_drawer")
end

vim.api.nvim_create_user_command("DiffDrawer", function()
  drawer().toggle()
end, { desc = "Toggle Diff Drawer" })

vim.api.nvim_create_user_command("DiffDrawerOpen", function()
  drawer().open()
end, { desc = "Open Diff Drawer" })

vim.api.nvim_create_user_command("DiffDrawerClose", function()
  drawer().close()
end, { desc = "Close Diff Drawer" })

vim.api.nvim_create_user_command("DiffDrawerFocus", function()
  drawer().focus()
end, { desc = "Focus Diff Drawer" })

vim.api.nvim_create_user_command("DiffDrawerRefresh", function()
  drawer().refresh()
end, { desc = "Refresh Diff Drawer" })

vim.api.nvim_create_user_command("DiffDrawerStageAll", function()
  drawer().stage_all()
end, { desc = "Stage all changes" })

vim.api.nvim_create_user_command("DiffDrawerUnstageAll", function()
  drawer().unstage_all()
end, { desc = "Unstage all changes" })

vim.api.nvim_create_user_command("DiffDrawerToggleLayout", function()
  drawer().toggle_layout()
end, { desc = "Toggle Diff Drawer tree/list layout" })
