local store = require("review.store")

local M = {}

---@type table<string, { handle: uv.uv_fs_event_t, timer: uv.uv_timer_t, last_seen: integer|nil }>
local watchers = {}

local function close(h)
  if h then
    h:stop()
    if not h:is_closing() then h:close() end
  end
end

--- Stop watching `path`, or every path when omitted.
function M.stop(path)
  for p, w in pairs(watchers) do
    if not path or p == path then
      close(w.handle)
      close(w.timer)
      watchers[p] = nil
    end
  end
end

function M.watching(path)
  return watchers[path] ~= nil or nil
end

--- Watch `path` (via its directory, since atomic renames replace the inode).
--- Calls on_change(review) on the main loop for changes Neovim didn't write itself.
---@param path string
---@param on_change fun(review: review.Review)
function M.start(path, on_change)
  if watchers[path] then
    watchers[path].on_change = on_change
    return
  end
  local w = {
    handle = assert(vim.uv.new_fs_event()),
    timer = assert(vim.uv.new_timer()),
    last_seen = store.mtime_ns(path),
    on_change = on_change,
  }
  watchers[path] = w

  local function check()
    if watchers[path] ~= w then return end
    local mt = store.mtime_ns(path)
    if not mt or mt == w.last_seen then return end
    w.last_seen = mt
    local own = store.last_written[path]
    if own and own.mtime_ns == mt then return end
    local review = store.read(path)
    if review then w.on_change(review) end
  end

  w.handle:start(vim.fs.dirname(path), {}, function(err)
    if err or watchers[path] ~= w then return end
    w.timer:stop()
    w.timer:start(150, 0, vim.schedule_wrap(check))
  end)
end

return M
