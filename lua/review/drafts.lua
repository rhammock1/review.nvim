-- Copies of unsent popup text, so a crash doesn't lose it.
local M = {}

M.dir = vim.fn.stdpath("state") .. "/review.nvim/drafts"
local MAX_AGE = 14 * 86400
local DELAY = 300

local pending = {} ---@type table<string, string|false> path -> text, or false to remove
local timer

local function path(key) return M.dir .. "/" .. vim.fn.sha256(key) .. ".json" end

local function write(file, text)
  if text == false then
    os.remove(file)
    return
  end
  vim.fn.mkdir(M.dir, "p")
  local tmp = file .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return end
  f:write(vim.json.encode({ text = text, at = os.time() }))
  f:close()
  vim.uv.fs_rename(tmp, file)
end

--- Write everything waiting now.
function M.flush()
  if timer then timer:stop() end
  local todo = pending
  pending = {}
  for file, text in pairs(todo) do pcall(write, file, text) end
end

local function later(file, text)
  pending[file] = text
  timer = timer or vim.uv.new_timer()
  timer:stop()
  timer:start(DELAY, 0, vim.schedule_wrap(M.flush))
end

--- Remember text for this key, or forget it when the text is empty.
---@param key string
---@param text string
function M.save(key, text)
  later(path(key), text ~= "" and text or false)
end

function M.clear(key)
  local file = path(key)
  pending[file] = nil
  os.remove(file)
end

--- Text left for this key, if any and recent.
---@return string|nil
function M.load(key)
  local file = path(key)
  local f = io.open(file, "r")
  if not f then return nil end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" or type(data.text) ~= "string" or type(data.at) ~= "number"
    or os.time() - data.at > MAX_AGE then
    os.remove(file)
    return nil
  end
  return data.text ~= "" and data.text or nil
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("review_drafts", { clear = true }),
  callback = function() M.flush() end,
})

return M
