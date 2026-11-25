local config = require("review.config")
local git = require("review.git")
local merge = require("review.merge")
local model = require("review.model")

local M = {}

--- path -> { review = Review, mtime_ns = integer } for the last write Neovim made.
M.last_written = {}

function M.slug(branch)
  return (branch:gsub("/", "-"))
end

function M.dir(toplevel)
  return toplevel .. "/" .. config.options.dir
end

local function escape(s)
  return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

local function max_n(toplevel, branch)
  local pat = "^%d%d%d%d%-%d%d%-%d%d%-" .. escape(M.slug(branch)) .. "%-(%d+)%.json$"
  local best, best_name = 0, nil
  for name, kind in vim.fs.dir(M.dir(toplevel)) do
    if kind == "file" then
      local n = tonumber(name:match(pat))
      if n and n > best then best, best_name = n, name end
    end
  end
  return best, best_name
end

function M.active_path(toplevel, branch)
  local _, name = max_n(toplevel, branch)
  return name and (M.dir(toplevel) .. "/" .. name) or nil
end

function M.new_path(toplevel, branch)
  local n = max_n(toplevel, branch) + 1
  return string.format("%s/%s-%s-%d.json", M.dir(toplevel), os.date("%Y-%m-%d"), M.slug(branch), n), n
end

local function mtime_ns(path)
  local st = vim.uv.fs_stat(path)
  return st and (st.mtime.sec * 1e9 + st.mtime.nsec) or nil
end
M.mtime_ns = mtime_ns

---@return review.Review|nil, string|nil
function M.read(path)
  local f = io.open(path, "r")
  if not f then return nil, nil end
  local s = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
  if not ok or type(data) ~= "table" then
    return nil, "review: can't parse " .. path .. ": " .. tostring(data)
  end
  local function bad(why)
    return nil, "review: malformed " .. path .. ": " .. why
  end
  if vim.islist(data) and #data > 0 then return bad("top level is not an object") end
  data.comments = data.comments or {}
  if type(data.comments) ~= "table" or not vim.islist(data.comments) then
    return bad("comments is not a list")
  end
  for i, c in ipairs(data.comments) do
    if type(c) ~= "table" or type(c.id) ~= "string" then
      return bad("comment #" .. i .. " has no id")
    end
    c.thread = c.thread or {}
    if type(c.thread) ~= "table" or not vim.islist(c.thread) then
      return bad("thread of " .. c.id .. " is not a list")
    end
    for _, m in ipairs(c.thread) do
      if type(m) ~= "table" or type(m.id) ~= "string" then
        return bad("a message in " .. c.id .. " has no id")
      end
    end
  end
  return data, nil
end

--- Re-read, merge, atomically write. Returns true, merged_review or false, err.
function M.write(path, review)
  local disk, err = M.read(path)
  if err then return false, err end
  local merged = merge.merge(disk, review)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local tmp = string.format("%s.tmp-%d", path, vim.uv.os_getpid())
  local f, ferr = io.open(tmp, "w")
  if not f then return false, ferr end
  f:write(vim.json.encode(merged, { indent = "  " }), "\n")
  f:close()
  local ok, rerr = vim.uv.fs_rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return false, rerr
  end
  M.last_written[path] = { review = merged, mtime_ns = mtime_ns(path) }
  return true, merged
end

function M.ensure_ignored(toplevel)
  if not config.options.ignore_review_dir then return end
  local rel = config.options.dir .. "/"
  if git.is_ignored(rel, toplevel) then return end
  local exclude = git.exclude_path(toplevel)
  if not exclude then return end
  vim.fn.mkdir(vim.fs.dirname(exclude), "p")
  local f = io.open(exclude, "a")
  if not f then return end
  f:write("\n" .. rel .. "\n")
  f:close()
end

--- Active review for the branch (or a fresh in-memory n=1 review). Nothing is written.
---@return review.Review, string
function M.load_active(toplevel, branch, base)
  local path = M.active_path(toplevel, branch)
  if path then
    local r, err = M.read(path)
    if r then return r, path end
    if err then vim.notify(err, vim.log.levels.WARN) end
  end
  if not path then path = M.new_path(toplevel, branch) end
  return model.new_review(branch, base, tonumber(path:match("%-(%d+)%.json$")) or 1), path
end

return M
