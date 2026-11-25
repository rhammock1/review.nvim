local M = {}

local function run(cmd, cwd)
  local ok, obj = pcall(vim.system, cmd, { cwd = cwd, text = true })
  if not ok then return nil end
  local r = obj:wait()
  if r.code ~= 0 then return nil end
  return vim.trim(r.stdout or "")
end

function M.toplevel(cwd)
  return run({ "git", "rev-parse", "--show-toplevel" }, cwd)
end

function M.sha(rev, cwd)
  return run({ "git", "rev-parse", "--verify", "--quiet", rev .. "^{commit}" }, cwd)
end

function M.branch(cwd)
  local b = run({ "git", "branch", "--show-current" }, cwd)
  if b and b ~= "" then return b end
  local short = run({ "git", "rev-parse", "--short", "HEAD" }, cwd) or "unknown"
  return "detached-" .. short
end

function M.exclude_path(cwd)
  local p = run({ "git", "rev-parse", "--git-path", "info/exclude" }, cwd)
  if not p then return nil end
  if p:sub(1, 1) ~= "/" then p = cwd .. "/" .. p end
  return p
end

--- Files git knows about, relative to the repo root.
---@return string[]
function M.files(cwd)
  local out = run({ "git", "ls-files", "--cached", "--others", "--exclude-standard" }, cwd)
  return out and out ~= "" and vim.split(out, "\n", { plain = true }) or {}
end

function M.is_ignored(path, cwd)
  local ok, obj = pcall(vim.system, { "git", "check-ignore", "-q", path }, { cwd = cwd })
  return ok and obj:wait().code == 0
end

return M
