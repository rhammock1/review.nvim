local M = {}

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

--- Supported agents. `source` is a directory in this plugin; `target` is where
--- the agent looks for it.
---@type table<string, { source: string, target: fun(): string }>
M.agents = {
  claude = {
    source = "skills/review-comments",
    target = function()
      local dir = vim.env.CLAUDE_CONFIG_DIR
      if not dir or dir == "" then dir = "~/.claude" end
      return vim.fs.normalize(dir) .. "/skills/review-comments"
    end,
  },
}

---@return string[]
function M.names()
  local names = vim.tbl_keys(M.agents)
  table.sort(names)
  return names
end

function M.source(agent)
  return root .. "/" .. M.agents[agent].source
end

local function fail(msg)
  vim.notify("review: " .. msg, vim.log.levels.ERROR)
  return false
end

--- Link the agent's files into place. Never replaces anything that already exists.
---@param agent? string
---@return boolean ok
function M.run(agent)
  local spec = M.agents[agent or ""]
  if not spec then
    local names = table.concat(M.names(), ", ")
    if not agent or agent == "" then return fail(":ReviewInstall needs an agent: " .. names) end
    return fail(string.format("unknown agent '%s' (supported: %s)", agent, names))
  end

  local source, target = M.source(agent), spec.target()
  if vim.uv.fs_lstat(target) then
    if vim.uv.fs_realpath(target) ~= vim.uv.fs_realpath(source) then
      return fail(target .. " already exists and isn't this plugin's copy; move it aside and run :ReviewInstall "
        .. agent .. " again")
    end
    vim.notify("review: already installed at " .. target)
  else
    local made, mkerr = pcall(vim.fn.mkdir, vim.fs.dirname(target), "p")
    if not made then return fail("can't create " .. vim.fs.dirname(target) .. ": " .. tostring(mkerr)) end
    local ok, err = vim.uv.fs_symlink(source, target, { dir = true })
    if not ok then return fail("can't link " .. target .. ": " .. tostring(err)) end
    vim.notify("review: installed " .. target)
  end
  if vim.fn.executable("jq") == 0 then
    vim.notify("review: review-watch needs jq, which isn't on your PATH", vim.log.levels.WARN)
  end
  return true
end

return M
