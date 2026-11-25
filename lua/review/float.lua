local config = require("review.config")
local export = require("review.export")

local M = {}

---@type { input_buf: integer, input_win: integer, thread_win?: integer, thread_buf?: integer, augroup: integer }|nil
M.state = nil

local MAX_HEIGHT = 15

function M.close()
  local s = M.state
  if not s then return end
  M.state = nil
  pcall(vim.api.nvim_del_augroup_by_id, s.augroup)
  for _, w in ipairs({ s.input_win, s.thread_win }) do
    if w and vim.api.nvim_win_is_valid(w) then pcall(vim.api.nvim_win_close, w, true) end
  end
  for _, b in ipairs({ s.input_buf, s.thread_buf }) do
    if b and vim.api.nvim_buf_is_valid(b) then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
  end
  if vim.fn.mode() == "i" then vim.cmd("stopinsert") end
end

local function body_of(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return vim.trim(table.concat(lines, "\n"))
end

local function first_key(list)
  return (list and list[1]) or "?"
end

local function title_for(ctx)
  return string.format(" %s  %s (%s) ", ctx.path, export.range(ctx), ctx.side)
end

local function thread_lines(comment)
  local out = {}
  for _, m in ipairs(comment.thread or {}) do
    local body = vim.split(m.body or "", "\n", { plain = true })
    local prefix = m.author .. (m.draft and " (draft)" or "") .. " ▸ "
    table.insert(out, prefix .. body[1])
    local pad = string.rep(" ", vim.fn.strdisplaywidth(prefix))
    for i = 2, #body do table.insert(out, pad .. body[i]) end
  end
  return out
end

local function text_height(win)
  local ok, h = pcall(vim.api.nvim_win_text_height, win, {})
  return ok and h.all or vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
end

--- Compute rows so the stack (thread? + input) sits below line_end, or above
--- line_start when there's no room below.
local function layout(ctx, thread_h, input_h)
  local win_h = vim.api.nvim_win_get_height(ctx.winid)
  local total = (thread_h > 0 and thread_h + 2 or 0) + input_h + 2
  local pos = vim.fn.screenpos(ctx.winid, ctx.line_end, 1)
  local winpos = vim.fn.win_screenpos(ctx.winid)
  local line_row = (pos.row > 0) and (pos.row - winpos[1]) or 0 -- 0-based row in window
  local below = win_h - line_row - 1
  if below >= total or line_row < total then
    return { line = ctx.line_end - 1, row = 1 }
  end
  return { line = ctx.line_start - 1, row = -total }
end

local function apply_layout(ctx)
  local s = M.state
  if not s then return end
  local width = math.min(80, vim.api.nvim_win_get_width(ctx.winid) - 4)
  local thread_h = 0
  if s.thread_win then
    thread_h = math.min(math.max(text_height(s.thread_win), 1), MAX_HEIGHT)
  end
  local input_h = math.min(math.max(text_height(s.input_win), 3), MAX_HEIGHT)
  local pos = layout(ctx, thread_h, input_h)
  local base = { relative = "win", win = ctx.winid, bufpos = { pos.line, 0 }, col = 0, width = width }
  local row = pos.row
  if s.thread_win then
    vim.api.nvim_win_set_config(s.thread_win, vim.tbl_extend("force", base, { row = row, height = thread_h }))
    row = row + thread_h + 2
  end
  vim.api.nvim_win_set_config(s.input_win, vim.tbl_extend("force", base, { row = row, height = input_h }))
end

local function scratch(ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = ft
  return buf
end

local function open(ctx, comment, on_submit, initial)
  M.close()
  local km = config.options.float_keymaps
  local width = math.min(80, vim.api.nvim_win_get_width(ctx.winid) - 4)
  local base = { relative = "win", win = ctx.winid, bufpos = { ctx.line_end - 1, 0 }, row = 1, col = 0,
                 width = width, height = 3, style = "minimal", border = "rounded" }

  local state = { augroup = vim.api.nvim_create_augroup("review_float", { clear = true }) }
  M.state = state

  if comment then
    state.thread_buf = scratch("markdown")
    vim.api.nvim_buf_set_lines(state.thread_buf, 0, -1, false, thread_lines(comment))
    vim.bo[state.thread_buf].modifiable = false
    state.thread_win = vim.api.nvim_open_win(state.thread_buf, false, vim.tbl_extend("force", base, {
      title = string.format(" thread · %s · %s ", comment.status, (title_for(ctx):gsub("^ ", ""))), title_pos = "left",
      focusable = true,
    }))
    vim.wo[state.thread_win].wrap = true
  end

  state.input_buf = scratch("markdown")
  if initial and initial ~= "" then
    vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, vim.split(initial, "\n", { plain = true }))
  end
  state.input_win = vim.api.nvim_open_win(state.input_buf, true, vim.tbl_extend("force", base, {
    title = comment and " reply " or title_for(ctx), title_pos = "left",
    footer = string.format(" %s save · %s post · %s cancel ",
      first_key(km.save_normal), first_key(km.post), first_key(km.cancel)),
    footer_pos = "right",
  }))
  vim.wo[state.input_win].wrap = true
  apply_layout(ctx)

  local function submit(post)
    local body = body_of(state.input_buf)
    if body == "" then
      vim.notify("review: empty comment", vim.log.levels.WARN)
      return
    end
    M.close()
    on_submit(body, post)
  end

  local function cancel()
    if body_of(state.input_buf) ~= "" and vim.fn.confirm("Discard comment?", "&Yes\n&No", 2) ~= 1 then
      return
    end
    M.close()
  end

  local o = { buffer = state.input_buf, nowait = true, silent = true }
  local post_default = config.options.post_on_submit
  for _, k in ipairs(km.save_normal or {}) do vim.keymap.set("n", k, function() submit(post_default) end, o) end
  for _, k in ipairs(km.save_insert or {}) do vim.keymap.set("i", k, function() submit(post_default) end, o) end
  for _, k in ipairs(km.post or {}) do vim.keymap.set({ "n", "i" }, k, function() submit(true) end, o) end
  for _, k in ipairs(km.cancel or {}) do vim.keymap.set("n", k, cancel, o) end
  if state.thread_buf then
    for _, k in ipairs(km.cancel or {}) do vim.keymap.set("n", k, M.close, { buffer = state.thread_buf, nowait = true }) end
  end

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = state.augroup, buffer = state.input_buf,
    callback = function() apply_layout(ctx) end,
  })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = state.augroup,
    callback = function()
      local w = vim.api.nvim_get_current_win()
      if M.state == state and w ~= state.input_win and w ~= state.thread_win then M.close() end
    end,
  })

  if not initial or initial == "" then vim.cmd("startinsert") end
end

---@param ctx review.Ctx
---@param on_submit fun(body: string, post: boolean)
---@param initial? string
function M.open_new(ctx, on_submit, initial)
  open(ctx, nil, on_submit, initial)
end

---@param ctx review.Ctx
---@param comment review.Comment
---@param on_submit fun(body: string, post: boolean)
function M.open_thread(ctx, comment, on_submit)
  open(ctx, comment, on_submit, nil)
end

return M
