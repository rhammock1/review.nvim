local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
-- Plugins come from REVIEW_TEST_DEPS (used in CI), else lazy.nvim's directory.
local deps = vim.env.REVIEW_TEST_DEPS
if not deps or deps == "" then deps = vim.fn.stdpath("data") .. "/lazy" end
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(deps .. "/plenary.nvim")
vim.opt.runtimepath:append(deps .. "/diffview.nvim")
vim.opt.runtimepath:append(deps .. "/telescope.nvim")
vim.opt.swapfile = false
vim.cmd("runtime plugin/plenary.vim")
package.path = root .. "/tests/?.lua;" .. package.path
