-- Copies of unsent popup text, so a crash doesn't lose it.
--
-- Each Neovim writes its own file per popup (<key hash>-<pid>.json). A copy is
-- only restored by the Neovim that wrote it, or once that Neovim has exited,
-- so two Neovims on one repo never take each other's text.
local M = {}

M.dir = vim.fn.stdpath("state") .. "/review.nvim/drafts"
M.pid = vim.uv.os_getpid()
local MAX_AGE = 14 * 86400
local DELAY, MAX_WAIT = 300, 2000 -- ms

local pending = {} ---@type table<string, string|false> file -> text, or false to remove
local first_pending ---@type integer|nil when the oldest unwritten change came in
local timer
local swept

local function hash(key) return vim.fn.sha256(key) end
local function own_file(key) return string.format("%s/%s-%d.json", M.dir, hash(key), M.pid) end

local function running(pid)
  if pid == M.pid then return true end
  local ok, err = vim.uv.kill(pid, 0)
  -- EPERM: it exists but belongs to someone else.
  return ok == 0 or (err ~= nil and err:find("EPERM", 1, true) ~= nil)
end

local function read(file)
  local f = io.open(file, "r")
  if not f then return nil end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, raw)
  if ok and type(data) == "table" and type(data.text) == "string" and type(data.at) == "number" then return data end
end

local function write(file, text)
  if text == false then
    os.remove(file)
    return
  end
  vim.fn.mkdir(M.dir, "p", tonumber("700", 8))
  local tmp = file .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return end
  vim.uv.fs_chmod(tmp, tonumber("600", 8))
  f:write(vim.json.encode({ text = text, at = os.time(), pid = M.pid }))
  f:close()
  vim.uv.fs_rename(tmp, file)
end

--- Write everything waiting now.
function M.flush()
  if timer then timer:stop() end
  local todo = pending
  pending, first_pending = {}, nil
  for file, text in pairs(todo) do pcall(write, file, text) end
end

local function later(file, text)
  pending[file] = text
  local now = vim.uv.now()
  first_pending = first_pending or now
  -- Steady typing never pauses; don't let the copy fall far behind.
  if now - first_pending >= MAX_WAIT then return M.flush() end
  timer = timer or vim.uv.new_timer()
  timer:stop()
  timer:start(DELAY, 0, vim.schedule_wrap(M.flush))
end

--- Remove copies older than two weeks, whoever left them.
function M.sweep()
  swept = true
  for _, file in ipairs(vim.fn.glob(M.dir .. "/*.json", false, true)) do
    local data = read(file)
    if not data or os.time() - data.at > MAX_AGE then os.remove(file) end
  end
end

--- Remember text for this key, or forget it when the text is empty.
---@param key string
---@param text string
function M.save(key, text)
  later(own_file(key), text ~= "" and text or false)
end

--- Forget this key's text: ours, and any taken over from Neovims that exited.
function M.clear(key)
  local mine = own_file(key)
  pending[mine] = nil
  os.remove(mine)
  for _, file in ipairs(vim.fn.glob(M.dir .. "/" .. hash(key) .. "-*.json", false, true)) do
    local data = read(file)
    if not data or not running(tonumber(data.pid) or -1) then os.remove(file) end
  end
end

--- The newest text left for this key by this Neovim or one that has exited.
---@return string|nil
function M.load(key)
  if not swept then M.sweep() end
  local best
  for _, file in ipairs(vim.fn.glob(M.dir .. "/" .. hash(key) .. "-*.json", false, true)) do
    local data = read(file)
    if not data or os.time() - data.at > MAX_AGE then
      os.remove(file)
    elseif data.text ~= "" and not (data.pid ~= M.pid and running(tonumber(data.pid) or -1))
      and (not best or data.at > best.at) then
      best = data
    end
  end
  return best and best.text or nil
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("review_drafts", { clear = true }),
  callback = function() M.flush() end,
})

return M
