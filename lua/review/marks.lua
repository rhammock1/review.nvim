local anchor = require("review.anchor")
local config = require("review.config")
local context = require("review.context")
local model = require("review.model")
local thread = require("review.thread")

local M = {}

M.ns = vim.api.nvim_create_namespace("review_marks")

local links = {
  PENDING = "DiagnosticHint", POSTED = "DiagnosticInfo",
  RESPONDED = "DiagnosticOk", RESOLVED = "Comment",
}
for status, link in pairs(links) do
  vim.api.nvim_set_hl(0, "Review" .. status, { link = link, default = true })
end

local function label(c, moved)
  local s = "💬 " .. #c.thread
  local last = c.thread[#c.thread]
  if c.status == "RESPONDED" and last and last.author == "agent" then
    s = s .. " · agent replied"
  end
  if thread.working(c) then s = s .. " · agent working" end
  if moved then s = s .. " · moved?" end
  return s
end

--- Visible comments for this buffer's path/side, each with its located range.
---@return { comment: review.Comment, loc: { start: integer, finish: integer, moved: boolean } }[]
local function located(bufnr, review, toplevel)
  local info = context.for_buffer(bufnr)
  if not info or (toplevel and info.toplevel ~= toplevel) then return {} end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local out = {}
  for _, c in ipairs(model.visible(review, config.options.show_resolved)) do
    if c.path == info.path and c.side == info.side then
      table.insert(out, { comment = c, loc = anchor.locate(lines, c) })
    end
  end
  return out
end

---@param bufnr integer
---@param review review.Review
---@param toplevel? string only mark buffers from this repo
function M.refresh(bufnr, review, toplevel)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  for _, item in ipairs(located(bufnr, review, toplevel)) do
    local c = item.comment
    local sign = config.options.signs[c.status] or "?"
    pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, item.loc.start - 1, 0, {
      sign_text = sign ~= "" and sign or nil,
      sign_hl_group = "Review" .. tostring(c.status),
      virt_text = { { label(c, item.loc.moved), "Comment" } },
      virt_text_pos = "eol",
      priority = 20,
    })
  end
end

function M.refresh_all(review, toplevel)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then M.refresh(b, review, toplevel) end
  end
end

--- First lines of the visible comments in a buffer, in order.
---@return integer[]
function M.starts(bufnr, review, toplevel)
  local seen, out = {}, {}
  for _, item in ipairs(located(bufnr, review, toplevel)) do
    if not seen[item.loc.start] then
      seen[item.loc.start] = true
      table.insert(out, item.loc.start)
    end
  end
  table.sort(out)
  return out
end

---@return review.Comment|nil, { start: integer, finish: integer, moved: boolean }|nil
function M.comment_at(bufnr, lnum, review, toplevel)
  if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  for _, item in ipairs(located(bufnr, review, toplevel)) do
    if lnum >= item.loc.start and lnum <= item.loc.finish then return item.comment, item.loc end
  end
end

return M
