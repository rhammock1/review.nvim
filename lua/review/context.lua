local git = require("review.git")

local M = {}

---@class review.Ctx: review.Location
---@field toplevel string
---@field base? string
---@field bufnr integer
---@field winid integer

local toplevel_cache = {}
local function toplevel_for(dir)
  if toplevel_cache[dir] == nil then
    toplevel_cache[dir] = git.toplevel(dir) or false
  end
  return toplevel_cache[dir] or nil
end

--- Diffview layout window + view showing `pred(win)`, if diffview is loaded.
local function find_diffview_win(pred)
  local lib = package.loaded["diffview.lib"]
  if not lib then return nil end
  for _, view in ipairs(lib.views or {}) do
    local layout = view.cur_layout
    if layout and layout.windows then
      for _, w in ipairs(layout.windows) do
        if w.file and pred(w) then return w, view end
      end
    end
  end
end

local function side_of(file)
  return file.symbol == "a" and "old" or "new"
end

local function is_local(file)
  local ok, RevType = pcall(function() return require("diffview.vcs.rev").RevType end)
  return ok and file.rev and file.rev.type == RevType.LOCAL
end

local function real_file_info(bufnr)
  if vim.bo[bufnr].buftype ~= "" then return nil end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or name:match("^%w+://") then return nil end
  local abs = vim.uv.fs_realpath(name) or name
  local top = toplevel_for(vim.fs.dirname(abs))
  if not top then return nil end
  local rel = vim.fs.relpath(top, abs)
  if not rel then return nil end
  return { toplevel = top, path = rel, side = "new" }
end

--- Which repo path and diff side a buffer shows (for placing marks).
function M.for_buffer(bufnr)
  if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  local w, view = find_diffview_win(function(win) return win.file.bufnr == bufnr end)
  if w then
    return { toplevel = view.adapter.ctx.toplevel, path = w.file.path, side = side_of(w.file) }
  end
  return real_file_info(bufnr)
end

---@param range? {integer, integer} line1, line2 (either order)
---@return review.Ctx|nil, string|nil
function M.current(range)
  local winid = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_get_current_buf()
  local l1, l2
  if range then
    l1, l2 = math.min(range[1], range[2]), math.max(range[1], range[2])
  else
    l1 = vim.api.nvim_win_get_cursor(winid)[1]
    l2 = l1
  end

  local ctx
  local w, view = find_diffview_win(function(win) return win.id == winid end)
  if w then
    local top = view.adapter.ctx.toplevel
    local file = w.file
    local worktree = is_local(file) and true or false
    local commit = worktree and git.sha("HEAD", top) or (file.rev and file.rev.commit)
    local left = view.cur_layout.a and view.cur_layout.a.file
    ctx = {
      toplevel = top, path = file.path, side = side_of(file),
      worktree = worktree, commit = commit,
      base = left and left.rev and left.rev.commit or nil,
    }
  else
    local info = real_file_info(bufnr)
    if not info then
      return nil, "review: not a file in a git repo (or a diffview panel)"
    end
    ctx = {
      toplevel = info.toplevel, path = info.path, side = "new",
      worktree = true, commit = git.sha("HEAD", info.toplevel),
    }
  end

  ctx.bufnr, ctx.winid = bufnr, winid
  ctx.line_start, ctx.line_end = l1, l2
  ctx.snippet = table.concat(vim.api.nvim_buf_get_lines(bufnr, l1 - 1, l2, false), "\n")
  return ctx, nil
end

return M
