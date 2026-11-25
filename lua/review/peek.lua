-- A small preview of a comment's newest message. Never takes focus.
local config = require("review.config")
local float = require("review.float")
local thread = require("review.thread")

local M = {}

local api = vim.api
local MAX_LINES, MAX_WIDTH = 3, 62

---@type integer|nil
M.win = nil
local augroup

function M.close()
  local win = M.win
  M.win = nil
  if augroup then pcall(api.nvim_del_augroup_by_id, augroup) end
  augroup = nil
  if win and api.nvim_win_is_valid(win) then pcall(api.nvim_win_close, win, true) end
end

---@param ctx { winid: integer, bufnr: integer, line_start: integer, line_end: integer }
---@param comment review.Comment
function M.show(ctx, comment)
  if M.win and api.nvim_win_is_valid(M.win) then return end
  M.close()
  local m = comment.thread[#comment.thread]
  if not m then return end
  local width = math.min(MAX_WIDTH, float.text_width(ctx.winid) - 2)
  if width < 10 then return end

  local lines = vim.tbl_filter(function(l) return l ~= "" end, thread.wrap(thread.body(m), width - 3))
  if #lines > MAX_LINES then
    lines = vim.list_slice(lines, 1, MAX_LINES)
    lines[MAX_LINES] = lines[MAX_LINES] .. "…"
  end
  if #lines == 0 then return end
  lines = vim.tbl_map(function(l) return " " .. l end, lines)

  local spots, total = float.spots(ctx), #lines + 2
  local spot = spots.below.free >= total and spots.below or spots.above.free >= total and spots.above
  if not spot then return end
  local pos = spot.at(total)

  local name, group = thread.name(m)
  local title = { { " " .. name .. " ", group } }
  local age = thread.ago(m.at, os.time())
  if age ~= "" then table.insert(title, { age .. " ", "ReviewTime" }) end
  local key = config.options.keymaps.comment
  local footer = key and { { " " .. key, "ReviewKey" }, { " open ", "ReviewTime" } } or { { "", "ReviewTime" } }

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  M.win = api.nvim_open_win(buf, false, {
    relative = "win", win = ctx.winid, bufpos = { pos.line, 0 }, row = pos.row, col = 0,
    width = width, height = #lines, style = "minimal", border = "rounded", focusable = false, noautocmd = true,
    title = title, title_pos = "left", footer = footer, footer_pos = "right",
  })
  vim.wo[M.win].wrap = false
  vim.wo[M.win].winhighlight = "FloatBorder:ReviewBorder"

  augroup = api.nvim_create_augroup("review_peek", { clear = true })
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter", "WinLeave", "BufLeave", "WinScrolled" }, {
    group = augroup,
    callback = function(a)
      -- Opening the preview itself counts as a scroll of the preview.
      if a.event == "WinScrolled" and tonumber(a.match) ~= ctx.winid then return end
      M.close()
    end,
  })
end

return M
