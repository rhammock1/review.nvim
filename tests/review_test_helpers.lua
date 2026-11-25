local M = {}

function M.sh(cmd, cwd)
  local r = vim.system(cmd, { cwd = cwd, text = true }):wait()
  assert(r.code == 0, table.concat(cmd, " ") .. ": " .. (r.stderr or ""))
  return vim.trim(r.stdout or "")
end

--- Temp git repo with one commit containing a.txt (10 lines). Returns realpath.
function M.repo(branch)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = vim.uv.fs_realpath(dir)
  M.sh({ "git", "init", "-q", "-b", branch or "feat/x" }, dir)
  M.sh({ "git", "config", "user.email", "t@t" }, dir)
  M.sh({ "git", "config", "user.name", "t" }, dir)
  M.sh({ "git", "config", "commit.gpgsign", "false" }, dir)
  local lines = {}
  for i = 1, 10 do lines[i] = "line " .. i end
  vim.fn.writefile(lines, dir .. "/a.txt")
  M.sh({ "git", "add", "." }, dir)
  M.sh({ "git", "commit", "-qm", "init" }, dir)
  return dir
end

function M.read(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

function M.write(path, s)
  local f = assert(io.open(path, "w"))
  f:write(s)
  f:close()
end

return M
