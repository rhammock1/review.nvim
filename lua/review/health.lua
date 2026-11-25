-- :checkhealth review
local M = {}

local function tool(name, missing_level, why)
  if vim.fn.executable(name) == 1 then
    vim.health.ok(name .. " found")
  else
    vim.health[missing_level](name .. " not found: install it; " .. why)
  end
end

local function plugin(module, name, missing_level, why)
  if pcall(require, module) then
    vim.health.ok(name .. " installed")
  else
    vim.health[missing_level](name .. " not installed: " .. why)
  end
end

function M.check()
  vim.health.start("review.nvim")
  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("Neovim " .. tostring(vim.version()))
  else
    vim.health.error("Neovim " .. tostring(vim.version()) .. " is too old: review.nvim needs 0.11 or newer")
  end
  if require("review.config").configured then
    vim.health.ok("setup() has run")
  else
    vim.health.warn("setup() hasn't run, so only :ReviewInstall is available: call require(\"review\").setup() (lazy.nvim does this when the spec has opts)")
  end
  tool("git", "error", "review.nvim needs it for everything")
  tool("jq", "warn", "the agent's review-watch script needs it")
  plugin("telescope", "telescope.nvim", "warn", ":ReviewList needs it")
  plugin("diffview", "diffview.nvim", "info", "comments still work in ordinary buffers")

  vim.health.start("review.nvim agent side")
  local install = require("review.install")
  for _, agent in ipairs(install.names()) do
    local target = install.agents[agent].target()
    local stat = vim.uv.fs_lstat(target)
    local parent = vim.uv.fs_stat(vim.fs.dirname(vim.fs.dirname(target)))
    if parent and parent.type ~= "directory" then
      vim.health.warn(agent .. ": " .. vim.fs.dirname(vim.fs.dirname(target)) .. " isn't a directory, so the skill can't be installed")
    elseif not stat then
      vim.health.info(agent .. ": not installed; run :ReviewInstall " .. agent)
    elseif vim.uv.fs_realpath(target) == vim.uv.fs_realpath(install.source(agent)) then
      vim.health.ok(agent .. ": installed at " .. target)
    else
      vim.health.warn(agent .. ": " .. target .. " isn't this plugin's copy; move it aside, then run :ReviewInstall " .. agent)
    end
  end
end

return M
