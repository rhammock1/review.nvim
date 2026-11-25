local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local lazy = vim.fn.stdpath("data") .. "/lazy"
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(lazy .. "/plenary.nvim")
vim.opt.runtimepath:append(lazy .. "/diffview.nvim")
vim.opt.runtimepath:append(lazy .. "/telescope.nvim")
vim.opt.swapfile = false
vim.cmd("runtime plugin/plenary.vim")
package.path = root .. "/tests/?.lua;" .. package.path
