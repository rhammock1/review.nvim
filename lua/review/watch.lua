local store = require("review.store")

local M = {}

local handle, timer, watched, last_seen

function M.stop()
  if handle then handle:stop(); if not handle:is_closing() then handle:close() end end
  if timer then timer:stop(); if not timer:is_closing() then timer:close() end end
  handle, timer, watched, last_seen = nil, nil, nil, nil
end

function M.path()
  return watched
end

--- Watch `path` (via its directory, since atomic renames replace the inode).
--- Calls on_change(review) on the main loop for changes Neovim didn't write itself.
---@param path string
---@param on_change fun(review: review.Review)
function M.start(path, on_change)
  if watched == path and handle then return end
  M.stop()
  watched = path
  last_seen = store.mtime_ns(path)
  handle = assert(vim.uv.new_fs_event())
  timer = assert(vim.uv.new_timer())

  local function check()
    local mt = store.mtime_ns(path)
    if not mt or mt == last_seen then return end
    last_seen = mt
    local own = store.last_written[path]
    if own and own.mtime_ns == mt then return end
    local review = store.read(path)
    if review then on_change(review) end
  end

  handle:start(vim.fs.dirname(path), {}, function(err)
    if err or not timer then return end
    timer:stop()
    timer:start(150, 0, vim.schedule_wrap(function()
      if watched == path then check() end
    end))
  end)
end

return M
