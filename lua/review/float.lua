local anchor = require("review.anchor")
local config = require("review.config")
local drafts = require("review.drafts")
local export = require("review.export")
local model = require("review.model")
local thread = require("review.thread")

local M = {}

---@class review.Popup
---@field ctx review.Ctx where the popup is anchored
---@field comment? review.Comment snapshot of the thread on show
---@field input_buf integer
---@field input_win integer
---@field thread_buf? integer
---@field thread_win? integer
---@field augroup integer
---@field initial string text the reply box started with
---@field pinned? boolean stays open when the cursor leaves (after posting)
---@field width? integer
---@field above? boolean
---@field draft_key string where unsent text is kept between sessions
---@field keep_draft? boolean the popup was closed by something else; keep the copy
---@type review.Popup|nil
M.state = nil

local api = vim.api
local MAX_HEIGHT, MAX_WIDTH, MIN_THREAD = 15, 80, 3
local ns = api.nvim_create_namespace("review_float")

local FULL = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" }
-- The thread's bottom edge is the divider; the reply box under it has no top.
local TOP = { "╭", "─", "╮", "│", "┤", "─", "├", "│" }
local BOTTOM = { "", "", "", "│", "╯", "─", "╰", "│" }

local drafts_key

local STATUS = { PENDING = "Draft", POSTED = "Posted", RESPONDED = "Replied", RESOLVED = "Resolved" }

local function valid(win) return win ~= nil and api.nvim_win_is_valid(win) end

--- Set options on this window only. vim.wo also changes the global value,
--- which windows opened later would pick up.
---@param win integer
---@param opts table<string, any>
function M.win_options(win, opts)
  for name, value in pairs(opts) do
    api.nvim_set_option_value(name, value, { scope = "local", win = win })
  end
end

local function status_group(status)
  return STATUS[status] and "Review" .. status or "ReviewTime"
end

--- Is the cursor in this popup?
local function focused(s)
  local w = api.nvim_get_current_win()
  return w == s.input_win or w == s.thread_win
end

function M.close()
  local s = M.state
  if not s then return end
  M.state = nil
  local inside = focused(s)
  if s.keep_draft then
    drafts.flush()
  else
    drafts.clear(s.draft_key)
  end
  pcall(api.nvim_del_augroup_by_id, s.augroup)
  pcall(api.nvim_buf_clear_namespace, s.ctx.bufnr, ns, 0, -1)
  for _, w in ipairs({ s.input_win, s.thread_win }) do
    if valid(w) then pcall(api.nvim_win_close, w, true) end
  end
  for _, b in ipairs({ s.input_buf, s.thread_buf }) do
    if b and api.nvim_buf_is_valid(b) then pcall(api.nvim_buf_delete, b, { force = true }) end
  end
  if inside and vim.fn.mode() == "i" then vim.cmd("stopinsert") end
end

local function body_of(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  return vim.trim(table.concat(lines, "\n"))
end

--- Does the popup hold text that hasn't been saved?
local function has_draft(s)
  return valid(s.input_win) and api.nvim_buf_is_valid(s.input_buf) and body_of(s.input_buf) ~= s.initial
end

local function return_to_draft()
  vim.notify("review: save or cancel this comment first", vim.log.levels.WARN)
  api.nvim_set_current_win(M.state.input_win)
end

--- When the cursor is in a popup with unsaved text, stay there. Returns whether it did.
---@return boolean
function M.hold_draft()
  local s, w = M.state, api.nvim_get_current_win()
  if not s or not has_draft(s) or (w ~= s.input_win and w ~= s.thread_win) then return false end
  return_to_draft()
  return true
end

--- Is the cursor in the popup? Returns the id of its thread, if it has one.
---@return boolean inside, string|nil id
function M.inside()
  local s, w = M.state, api.nvim_get_current_win()
  if not s or (w ~= s.input_win and w ~= s.thread_win) then return false end
  return true, s.comment and s.comment.id
end

--- Can the user see this comment's thread right now?
function M.showing(id)
  local s = M.state
  return s ~= nil and s.comment ~= nil and s.comment.id == id and valid(s.thread_win)
    and api.nvim_win_get_tabpage(s.thread_win) == api.nvim_get_current_tabpage()
    and not api.nvim_win_get_config(s.thread_win).hide
end

-- Frame text -----------------------------------------------------------------

local function chunk_cells(chunks)
  local n = 0
  for _, c in ipairs(chunks) do n = n + vim.fn.strdisplaywidth(c[1]) end
  return n
end

--- A border line with text at both ends. Neovim places a title or footer at
--- one spot only, so the middle is drawn as border. `rights` is tried in order
--- until one fits; `left` is always kept.
local function frame(width, left, rights)
  local room = width - chunk_cells(left)
  local right = {}
  for _, r in ipairs(rights) do
    if chunk_cells(r) + 1 <= room then right = r break end
  end
  local out = vim.list_extend({}, left)
  local fill = room - chunk_cells(right)
  if fill > 0 then table.insert(out, { string.rep("─", fill), "ReviewBorder" }) end
  return vim.list_extend(out, right)
end

local function title(s)
  local left
  if s.comment then
    local status = s.comment.status
    local sign = config.options.signs[status] or ""
    left = { { " " .. (sign ~= "" and sign .. " " or "") .. (STATUS[status] or tostring(status)) .. " ",
      status_group(status) } }
  else
    left = { { s.initial ~= "" and " Edit comment " or " New comment ", "ReviewYou" } }
  end
  local where = string.format("%s (%s) ", export.range(s.ctx), s.ctx.side)
  local function right(path) return { { " " .. path .. " ", "FloatTitle" }, { where, "ReviewTime" } } end
  return frame(s.width, left, { right(s.ctx.path), right(vim.fs.basename(s.ctx.path)), { { " " .. where, "ReviewTime" } } })
end

local function hints(s)
  local km = config.options.float_keymaps
  local long, short = {}, {}
  for _, h in ipairs({
    { km.save_normal[1], config.options.post_on_submit and "post" or "save" },
    { km.post[1], "post" },
    { km.cancel[1], "close" },
  }) do
    if h[1] then
      vim.list_extend(long, { { " " .. h[1], "ReviewKey" }, { " " .. h[2] .. " ", "ReviewTime" } })
      vim.list_extend(short, { { " " .. h[1] .. " ", "ReviewKey" } })
    end
  end
  return frame(s.width, {}, { long, short })
end

--- Buffer lines of the thread hidden above and below.
local function hidden(s)
  local info = vim.fn.getwininfo(s.thread_win)[1]
  return info.topline - 1, math.max(api.nvim_buf_line_count(s.thread_buf) - info.botline, 0)
end

local function divider(s)
  local up, down = hidden(s)
  local km = config.options.float_keymaps
  local rights = {}
  if up > 0 or down > 0 then
    local counts = {}
    if up > 0 then table.insert(counts, "▲ " .. up) end
    if down > 0 then table.insert(counts, "▼ " .. down) end
    local text = " " .. table.concat(counts, "  ") .. " more "
    local keys = {}
    if up > 0 and km.scroll_up[1] then table.insert(keys, km.scroll_up[1]) end
    if down > 0 and km.scroll_down[1] then table.insert(keys, km.scroll_down[1]) end
    if #keys > 0 then
      table.insert(rights, { { text, "ReviewTime" }, { table.concat(keys, " ") .. " ", "ReviewKey" } })
    end
    table.insert(rights, { { text, "ReviewTime" } })
  end
  return frame(s.width, { { " Reply ", "ReviewYou" } }, rights)
end

-- Layout ---------------------------------------------------------------------

local function text_height(win)
  local ok, h = pcall(api.nvim_win_text_height, win, {})
  return ok and h.all or api.nvim_buf_line_count(api.nvim_win_get_buf(win))
end

--- Columns available for text in a window (without number and sign columns).
function M.text_width(win)
  return api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
end

--- Screen rows free below and above the commented lines, and the float
--- positions that use them. Lines scrolled out of view count as the edge.
function M.spots(ctx)
  local win = ctx.winid
  local first, last = vim.fn.line("w0", win), vim.fn.line("w$", win)
  local function row(line, col)
    local pos = vim.fn.screenpos(win, line, col)
    return pos.row > 0 and pos.row - vim.fn.win_screenpos(win)[1] or nil
  end
  local s = math.min(math.max(ctx.line_start, first), last)
  local e = math.min(math.max(ctx.line_end, first), last)
  local s_row, e_row = row(s, 1) or 0, row(e, 1) or 0
  -- A wrapped line ends further down than it starts.
  local text = api.nvim_buf_get_lines(api.nvim_win_get_buf(win), e - 1, e, false)[1] or ""
  local e_end = math.max(row(e, math.max(#text, 1)) or e_row, e_row)
  local height = api.nvim_win_get_height(win)
  return {
    height = height,
    below = { free = height - e_end - 1, at = function() return { line = e - 1, row = e_end - e_row + 1 } end },
    above = { free = s_row, at = function(total) return { line = s - 1, row = -total } end },
    -- Over the code, at the bottom of the window, when neither side has room.
    over = { free = height, at = function(total) return { line = first - 1, row = math.max(height - total, 0) } end },
  }
end

--- Pick a spot and the heights that fit it.
local function fit(s, thread_h, input_h)
  local chrome = s.thread_win and 3 or 2
  local spots = M.spots(s.ctx)
  local order = s.above and { spots.above, spots.below } or { spots.below, spots.above }
  local spot
  for _, o in ipairs(order) do
    if not spot and o.free >= chrome + thread_h + input_h then spot = o end
  end
  if not spot then
    local best = spots.above.free > spots.below.free and spots.above or spots.below
    local least = chrome + math.min(thread_h, MIN_THREAD) + input_h
    spot = best.free >= least and best or spots.over
    local room = spot.free - chrome
    if s.thread_win then
      thread_h = math.max(math.min(thread_h, room - input_h), math.min(thread_h, MIN_THREAD, math.max(room - 1, 1)))
    end
    input_h = math.max(math.min(input_h, room - thread_h), 1)
  end
  s.above = spot == spots.above
  return spot.at(chrome + thread_h + input_h), thread_h, input_h
end

--- The last topline that still fills the thread window.
local function last_top(s)
  local height = api.nvim_win_get_height(s.thread_win)
  local n = api.nvim_buf_line_count(s.thread_buf)
  local top = n
  while top > 1 do
    local ok, h = pcall(api.nvim_win_text_height, s.thread_win, { start_row = top - 2, end_row = n - 1 })
    if not ok or h.all > height then break end
    top = top - 1
  end
  return top
end

local function set_top(s, top)
  top = math.max(math.min(top, last_top(s)), 1)
  api.nvim_win_call(s.thread_win, function()
    local view = { topline = top, leftcol = 0, skipcol = 0 }
    -- Leave the cursor where it is when it's still in view.
    local lnum = vim.fn.line(".")
    if lnum < top or lnum >= top + api.nvim_win_get_height(s.thread_win) then view.lnum, view.col = top, 0 end
    vim.fn.winrestview(view)
  end)
end

local function at_bottom(s)
  local info = vim.fn.getwininfo(s.thread_win)[1]
  return info.topline >= last_top(s)
end

local function draw_divider(s)
  if M.state ~= s or not valid(s.thread_win) then return end
  api.nvim_win_set_config(s.thread_win, { border = TOP, footer = divider(s), footer_pos = "left" })
end

local function draw_thread(s)
  local lines, marks = thread.render(s.comment, s.width)
  -- Replace only what changed, so a cursor or selection in the thread stays put.
  local old = api.nvim_buf_get_lines(s.thread_buf, 0, -1, false)
  local same = 0
  while same < #old and same < #lines and old[same + 1] == lines[same + 1] do same = same + 1 end
  vim.bo[s.thread_buf].modifiable = true
  api.nvim_buf_set_lines(s.thread_buf, same, -1, false, vim.list_slice(lines, same + 1))
  vim.bo[s.thread_buf].modifiable = false
  api.nvim_buf_clear_namespace(s.thread_buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    pcall(api.nvim_buf_set_extmark, s.thread_buf, ns, m.row, m.col, m.opts)
  end
end

local function draw_placeholder(s)
  if not api.nvim_buf_is_valid(s.input_buf) then return end
  api.nvim_buf_clear_namespace(s.input_buf, ns, 0, -1)
  local lines = api.nvim_buf_get_lines(s.input_buf, 0, 2, false)
  if #lines > 1 or (lines[1] or "") ~= "" then return end
  api.nvim_buf_set_extmark(s.input_buf, ns, 0, 0, {
    virt_text = { { s.comment and "Write a reply…" or "Write a comment…", "ReviewTime" } },
    virt_text_pos = "overlay",
  })
end

--- Mark the commented lines while the popup is open.
local function draw_range(s)
  if not api.nvim_buf_is_valid(s.ctx.bufnr) then return end
  api.nvim_buf_clear_namespace(s.ctx.bufnr, ns, 0, -1)
  local group = s.comment and status_group(s.comment.status) or "ReviewYou"
  for l = s.ctx.line_start, math.min(s.ctx.line_end, api.nvim_buf_line_count(s.ctx.bufnr)) do
    pcall(api.nvim_buf_set_extmark, s.ctx.bufnr, ns, l - 1, 0,
      { sign_text = "▎", sign_hl_group = group, number_hl_group = group, priority = 30 })
  end
end

local function width_for(ctx)
  return math.max(math.min(MAX_WIDTH, M.text_width(ctx.winid) - 2), 1)
end

--- Are the commented lines scrolled out of view?
local function offscreen(s)
  return s.ctx.line_end < vim.fn.line("w0", s.ctx.winid) or s.ctx.line_start > vim.fn.line("w$", s.ctx.winid)
end

--- Update where the commented lines are now.
local function relocate(s)
  if not s.comment or not api.nvim_buf_is_valid(s.ctx.bufnr) then return end
  local loc = anchor.locate(api.nvim_buf_get_lines(s.ctx.bufnr, 0, -1, false), s.comment)
  if not loc.moved then s.ctx.line_start, s.ctx.line_end = loc.start, loc.finish end
end

--- Size and place the popup. `follow` keeps the newest message in view.
local function apply_layout(s, follow)
  if M.state ~= s or not valid(s.ctx.winid) or not valid(s.input_win) then return end
  if s.thread_win and not valid(s.thread_win) then s.thread_win = nil end
  -- Out of the way while its code is scrolled off, unless the cursor is in it.
  local hide = offscreen(s) and not focused(s)
  local width = width_for(s.ctx)
  local rewrap = width ~= s.width
  s.width = width

  local top
  if s.thread_win then
    follow = follow or (at_bottom(s) and api.nvim_get_current_win() ~= s.thread_win)
    top = vim.fn.getwininfo(s.thread_win)[1].topline
    api.nvim_win_set_width(s.thread_win, width)
    if rewrap then draw_thread(s) end
  end
  api.nvim_win_set_width(s.input_win, width)

  local thread_h = s.thread_win and math.min(math.max(text_height(s.thread_win), 1), MAX_HEIGHT) or 0
  local input_h = math.min(math.max(text_height(s.input_win), 1), MAX_HEIGHT)
  local pos
  pos, thread_h, input_h = fit(s, thread_h, input_h)

  local base = { relative = "win", win = s.ctx.winid, bufpos = { pos.line, 0 }, col = 0, width = width, hide = hide }
  local row = pos.row
  if s.thread_win then
    api.nvim_win_set_config(s.thread_win, vim.tbl_extend("force", base, {
      row = row, height = thread_h, border = TOP, title = title(s), title_pos = "left" }))
    set_top(s, follow and math.huge or top)
    draw_divider(s)
    row = row + thread_h + 2
  end
  local input = vim.tbl_extend("force", base, { row = row, height = input_h,
    border = s.thread_win and BOTTOM or FULL, footer = hints(s), footer_pos = "left" })
  if not s.thread_win then input.title, input.title_pos = title(s), "left" end
  api.nvim_win_set_config(s.input_win, input)
end

-- Windows --------------------------------------------------------------------

local function scratch()
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  return buf
end

local function open_win(s, buf, enter, border)
  local win = api.nvim_open_win(buf, enter, { relative = "win", win = s.ctx.winid,
    bufpos = { s.ctx.line_end - 1, 0 }, row = 1, col = 0, width = s.width, height = 1,
    style = "minimal", border = border })
  M.win_options(win, { wrap = true, winfixbuf = true, scrolloff = 0, foldenable = false,
    winhighlight = "FloatBorder:ReviewBorder" })
  return win
end

--- Show the thread above the reply box, opening its window if needed.
local function show_thread(s, follow)
  if not valid(s.thread_win) then
    s.thread_buf = scratch()
    s.thread_win = open_win(s, s.thread_buf, false, TOP)
    local o = { buffer = s.thread_buf, nowait = true, silent = true }
    for _, k in ipairs(config.options.float_keymaps.cancel) do vim.keymap.set("n", k, s.cancel, o) end
    vim.keymap.set("n", "<C-w>j", function()
      if valid(s.input_win) then api.nvim_set_current_win(s.input_win) end
    end, o)
    api.nvim_create_autocmd("WinScrolled", {
      group = s.augroup, pattern = tostring(s.thread_win),
      callback = function() draw_divider(s) end,
    })
  end
  draw_thread(s)
  relocate(s)
  draw_range(s)
  apply_layout(s, follow)
end

--- Redraw the open thread from the review, if it's showing one of its comments.
---@param review review.Review
function M.update(review)
  local s = M.state
  if not s or not s.comment then return end
  local c = model.find(review, s.comment.id)
  if not c or (c.status == s.comment.status and vim.deep_equal(c.thread, s.comment.thread)) then return end
  s.comment = vim.deepcopy(c)
  if not valid(s.thread_win) or not valid(s.ctx.winid) then return end
  show_thread(s, at_bottom(s) and api.nvim_get_current_win() ~= s.thread_win)
end

local function scroll(s, dir)
  if not valid(s.thread_win) then return end
  local half = math.max(math.floor(api.nvim_win_get_height(s.thread_win) / 2), 1)
  set_top(s, vim.fn.getwininfo(s.thread_win)[1].topline + dir * half)
  draw_divider(s)
end

--- Where unsent text for this popup is kept: per repo and comment, or per
--- lines for a new comment.
drafts_key = function(ctx, comment, initial)
  local where = comment and ("comment " .. comment.id)
    or string.format("%s %s:%d-%d", (initial or "") ~= "" and "edit " .. vim.fn.sha256(initial) or "new",
      ctx.path, ctx.line_start, ctx.line_end) .. " " .. tostring(ctx.side)
  return tostring(ctx.toplevel) .. "\0" .. where
end

local function open(ctx, comment, on_submit, initial)
  local prev = M.state
  if prev and comment and prev.comment and prev.comment.id == comment.id and valid(prev.input_win) then
    return api.nvim_set_current_win(prev.input_win)
  end
  if prev and has_draft(prev) then return return_to_draft() end
  M.close()
  local km = config.options.float_keymaps

  ctx = vim.deepcopy(ctx)
  if comment then
    local loc = anchor.locate(api.nvim_buf_get_lines(ctx.bufnr, 0, -1, false), comment)
    ctx.line_start, ctx.line_end = loc.start, loc.finish
  end

  ---@type review.Popup
  local s = {
    ctx = ctx,
    comment = comment and vim.deepcopy(comment) or nil,
    augroup = api.nvim_create_augroup("review_float", { clear = true }),
    initial = vim.trim(initial or ""),
    width = width_for(ctx),
  }
  M.state = s

  local function submit(post)
    local body = body_of(s.input_buf)
    if body == "" then
      vim.notify("review: empty comment", vim.log.levels.WARN)
      return
    end
    drafts.clear(s.draft_key)
    if not post then
      M.close()
      on_submit(body, false)
      return
    end
    -- Posting keeps the popup open as a conversation.
    local posted = on_submit(body, true)
    if M.state ~= s then return end
    if not posted or not valid(s.input_win) or not valid(s.ctx.winid) then return M.close() end
    s.comment, s.initial, s.pinned = vim.deepcopy(posted), "", true
    s.draft_key = drafts_key(ctx, s.comment, nil)
    api.nvim_buf_set_lines(s.input_buf, 0, -1, false, { "" })
    draw_placeholder(s)
    show_thread(s, true)
  end

  function s.cancel()
    if body_of(s.input_buf) ~= "" and vim.fn.confirm("Discard comment?", "&Yes\n&No", 2) ~= 1 then
      return
    end
    M.close()
  end

  s.input_buf = scratch()
  s.draft_key = drafts_key(ctx, s.comment, initial)
  local restored = drafts.load(s.draft_key)
  local text = restored or initial
  if text and text ~= "" then
    api.nvim_buf_set_lines(s.input_buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  end
  if restored then vim.notify("review: restored text you hadn't sent") end
  s.input_win = open_win(s, s.input_buf, true, FULL)
  M.win_options(s.input_win, { statuscolumn = " " }) -- lines the text up with the thread

  local o = { buffer = s.input_buf, nowait = true, silent = true }
  local post_default = config.options.post_on_submit
  for _, k in ipairs(km.save_normal) do vim.keymap.set("n", k, function() submit(post_default) end, o) end
  for _, k in ipairs(km.save_insert) do vim.keymap.set("i", k, function() submit(post_default) end, o) end
  for _, k in ipairs(km.post) do vim.keymap.set({ "n", "i" }, k, function() submit(true) end, o) end
  for _, k in ipairs(km.cancel) do vim.keymap.set("n", k, s.cancel, o) end
  for _, k in ipairs(km.scroll_up) do vim.keymap.set({ "n", "i" }, k, function() scroll(s, -1) end, o) end
  for _, k in ipairs(km.scroll_down) do vim.keymap.set({ "n", "i" }, k, function() scroll(s, 1) end, o) end
  -- Neovim's own <C-w>k skips floating windows.
  vim.keymap.set("n", "<C-w>k", function()
    if valid(s.thread_win) then api.nvim_set_current_win(s.thread_win) end
  end, o)

  if s.comment then show_thread(s, true) else draw_range(s) apply_layout(s) end
  draw_placeholder(s)

  local function on(events, opts, callback)
    api.nvim_create_autocmd(events, vim.tbl_extend("force", { group = s.augroup, callback = callback }, opts))
  end
  on({ "TextChanged", "TextChangedI", "TextChangedP" }, { buffer = s.input_buf }, function()
    drafts.save(s.draft_key, has_draft(s) and body_of(s.input_buf) or "")
    draw_placeholder(s)
    apply_layout(s)
  end)
  on({ "VimResized", "WinResized" }, {}, function()
    vim.schedule(function() apply_layout(s) end)
  end)
  on("WinEnter", {}, function()
    local w = api.nvim_get_current_win()
    if vim.w[w].review_help then return end
    if M.state ~= s then return end
    if focused(s) then return apply_layout(s) end
    -- A conversation stays open, and so does unsaved text, so leaving can't lose it.
    if (s.pinned and valid(s.input_win)) or has_draft(s) then return apply_layout(s) end
    M.close()
  end)
  -- The pattern only names the first window that scrolled; scroll-bound diff
  -- panes move ours along with another, so look at every window that did.
  on("WinScrolled", {}, function()
    if vim.v.event[tostring(ctx.winid)] then vim.schedule(function() apply_layout(s) end) end
  end)
  -- :q, :only and :tabclose skip our own close; don't lose what was typed.
  on("WinClosed", { pattern = tostring(s.input_win) }, function()
    if M.state ~= s or not has_draft(s) then return end
    s.keep_draft = true
    drafts.save(s.draft_key, body_of(s.input_buf))
    vim.fn.setreg('"', body_of(s.input_buf))
    vim.notify("review: popup closed; your text is in the unnamed register (paste with p)", vim.log.levels.WARN)
  end)
  -- Don't float over a different file.
  on({ "BufWinEnter", "WinClosed" }, {}, function()
    vim.schedule(function()
      if M.state ~= s or has_draft(s) then return end
      if not valid(s.input_win) then return M.close() end
      if not valid(ctx.winid) or api.nvim_win_get_buf(ctx.winid) ~= ctx.bufnr then M.close() end
    end)
  end)

  if restored then
    api.nvim_win_set_cursor(s.input_win, { api.nvim_buf_line_count(s.input_buf), 0 })
    vim.cmd("startinsert!")
  elseif not initial or initial == "" then
    vim.cmd("startinsert")
  end
end

---@param ctx review.Ctx
---@param on_submit fun(body: string, post: boolean): review.Comment|nil the posted comment, to keep it open
---@param initial? string
function M.open_new(ctx, on_submit, initial)
  open(ctx, nil, on_submit, initial)
end

---@param ctx review.Ctx
---@param comment review.Comment
---@param on_submit fun(body: string, post: boolean): review.Comment|nil the posted comment, to keep it open
function M.open_thread(ctx, comment, on_submit)
  open(ctx, comment, on_submit, nil)
end

return M
