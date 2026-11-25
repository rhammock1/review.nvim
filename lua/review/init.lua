local anchor = require("review.anchor")
local config = require("review.config")
local context = require("review.context")
local export = require("review.export")
local float = require("review.float")
local git = require("review.git")
local marks = require("review.marks")
local merge = require("review.merge")
local model = require("review.model")
local peek = require("review.peek")
local store = require("review.store")
local watch = require("review.watch")

local M = {}

---@class review.Session
---@field toplevel string
---@field branch string
---@field path string
---@field review review.Review
---@field ignored? boolean

---@type table<string, review.Session>
local sessions = {}
local mapped = {}

local function notify(msg, level)
  vim.notify("review: " .. msg, level)
end

--- Notify about comments that gained agent messages between two snapshots.
local function announce_agent_replies(old, new)
  local before = {}
  for _, c in ipairs(old.comments or {}) do
    local n = 0
    for _, m in ipairs(c.thread) do if m.author == "agent" then n = n + 1 end end
    before[c.id] = n
  end
  for _, c in ipairs(new.comments or {}) do
    local n = 0
    for _, m in ipairs(c.thread) do if m.author == "agent" then n = n + 1 end end
    if not c.deleted and n > (before[c.id] or 0) and not float.showing(c.id) then
      notify(string.format("agent replied on %s:%d", vim.fs.basename(c.path), c.line_start))
    end
  end
end

local save

local function redraw(s)
  marks.refresh_all(s.review, s.toplevel)
  float.update(s.review)
end

local function start_watch(s)
  watch.start(s.path, function(disk)
    if sessions[s.toplevel] ~= s then return end
    local old = s.review
    -- Merge rather than replace: memory may hold user changes the disk lacks
    -- (a save that failed, or a write the agent's copy raced over).
    s.review = merge.merge(disk, old)
    announce_agent_replies(old, s.review)
    if not vim.deep_equal(s.review, merge.merge(disk, disk)) then
      save(s)
    else
      redraw(s)
    end
  end)
end

---@return review.Session
local function session_for(toplevel, base)
  local branch = git.branch(toplevel)
  local s = sessions[toplevel]
  if s and s.branch == branch then return s end
  if s then watch.stop(s.path) end
  local review, path = store.load_active(toplevel, branch, base)
  s = { toplevel = toplevel, branch = branch, path = path, review = review }
  sessions[toplevel] = s
  if vim.uv.fs_stat(path) then start_watch(s) end
  return s
end

--- Session for the current buffer, falling back to the cwd's repo.
---@return review.Session|nil, review.Ctx|nil
local function current_session(range)
  local ctx = context.current(range)
  local top = ctx and ctx.toplevel or git.toplevel(vim.fn.getcwd())
  if not top then
    notify("not in a git repo", vim.log.levels.WARN)
    return nil
  end
  return session_for(top, ctx and ctx.base), ctx
end

function save(s)
  if not s.ignored then
    store.ensure_ignored(s.toplevel)
    s.ignored = true
  end
  local ok, res = store.write(s.path, s.review)
  if not ok then
    notify(tostring(res), vim.log.levels.ERROR)
    return false
  end
  s.review = res
  redraw(s)
  start_watch(s)
  return true
end

local function comment_under_cursor(s)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  return marks.comment_at(0, lnum, s.review, s.toplevel)
end

--- Don't lose text that can no longer be saved where it was meant to go.
local function keep_text(body, why)
  vim.fn.setreg('"', body)
  notify(why .. "; your text is in the unnamed register (paste with p)", vim.log.levels.WARN)
end

--- Add a reply. Returns the comment when it was posted, so its thread stays open.
local function reply(s, id, body, post)
  local live = model.find(s.review, id)
  if not live or live.deleted then return keep_text(body, "that comment is gone") end
  model.reply(live, body, post)
  save(s)
  return post and model.find(s.review, id) or nil
end

local function open_thread(s, ctx, c)
  float.open_thread(ctx, c, function(body, post) return reply(s, c.id, body, post) end)
end

--- New comment on the line/range, or the existing thread when the cursor
--- (no explicit range) is on a commented line.
---@param range? {integer, integer}
function M.comment(range)
  local s, ctx = current_session(range)
  if not s then return end
  if not ctx then
    notify("can't comment here (not a file in this repo)", vim.log.levels.WARN)
    return
  end
  if not range then
    local existing = comment_under_cursor(s)
    if existing then return open_thread(s, ctx, existing) end
  end
  local id -- set once posted: the popup then holds that comment's thread
  float.open_new(ctx, function(body, post)
    if id then return reply(s, id, body, post) end
    if not s.review.base and ctx.base then s.review.base = ctx.base end
    local c = model.new_comment(ctx, body, post)
    table.insert(s.review.comments, c)
    save(s)
    if not post then return end
    id = c.id
    return model.find(s.review, id)
  end)
end

function M.thread()
  local s, ctx = current_session()
  if not s or not ctx then return end
  local c = comment_under_cursor(s)
  if not c then return notify("no comment here") end
  open_thread(s, ctx, c)
end

function M.submit()
  local s = current_session()
  if not s then return end
  local n = 0
  for _, c in ipairs(s.review.comments) do
    if not c.deleted and model.post(c) then n = n + 1 end
  end
  if n == 0 then return notify("nothing pending") end
  if save(s) then notify(string.format("posted %d comment%s", n, n == 1 and "" or "s")) end
end

function M.resolve()
  local s = current_session()
  if not s then return end
  local _, id = float.inside()
  local c = id and model.find(s.review, id) or comment_under_cursor(s)
  if not c then return notify("no comment here") end
  model.resolve(c)
  save(s)
end

function M.new()
  local s = current_session()
  if not s then return end
  local path, n = store.new_path(s.toplevel, s.branch)
  watch.stop(s.path)
  s.path = path
  s.review = model.new_review(s.branch, s.review.base, n)
  if save(s) then notify("started review #" .. n) end
end

function M.export()
  local s = current_session()
  if s then export.run(s.review) end
end

--- Does this diffview view list `path` among its files?
local function view_has(view, path)
  if not (view.files and view.files.iter) then return false end
  for _, f in view.files:iter() do
    if f.path == path then return true end
  end
  return false
end

local function jump_to_file(s, c, after)
  vim.cmd("edit " .. vim.fn.fnameescape(s.toplevel .. "/" .. c.path))
  local loc = anchor.locate(vim.api.nvim_buf_get_lines(0, 0, -1, false), c)
  vim.api.nvim_win_set_cursor(0, { loc.start, 0 })
  vim.cmd("normal! zz")
  marks.refresh(0, s.review, s.toplevel)
  if after then after() end
end

--- Put the cursor on a comment: inside an open diffview for the repo when it
--- lists the file, otherwise in the real file.
local function jump(s, c, after)
  local lib = package.loaded["diffview.lib"]
  local view = lib and lib.get_current_view()
  if not (view and view.adapter and view.adapter.ctx.toplevel == s.toplevel
          and view.set_file_by_path and view_has(view, c.path)) then
    return jump_to_file(s, c, after)
  end
  view:set_file_by_path(c.path, true, true)
  local tries = 0
  local function land()
    tries = tries + 1
    local layout = view.cur_layout
    local w = layout and (c.side == "old" and layout.a or layout.b)
    local ready = w and w.file and w.file.path == c.path and vim.api.nvim_win_is_valid(w.id)
      and vim.api.nvim_win_get_buf(w.id) == w.file.bufnr
    if not ready then
      if tries < 40 then
        vim.defer_fn(land, 25)
      else
        notify("couldn't open " .. c.path .. " in diffview; opening the file instead")
        jump_to_file(s, c, after)
      end
      return
    end
    vim.api.nvim_set_current_win(w.id)
    local loc = anchor.locate(vim.api.nvim_buf_get_lines(w.file.bufnr, 0, -1, false), c)
    vim.api.nvim_win_set_cursor(w.id, { loc.start, 0 })
    vim.cmd("normal! zz")
    if after then after() end
  end
  land()
end

function M.list(show_resolved)
  if float.hold_draft() then return end
  -- Jumping from the list would open the file inside the popup.
  if float.inside() then float.close() end
  local s = current_session()
  if not s then return end
  local function live(c) return model.find(s.review, c.id) or c end
  require("review.picker").open(s.review, {
    jump = function(c) jump(s, c) end,
    reply = function(c)
      jump(s, c, function()
        local ctx = context.current()
        if ctx then open_thread(s, ctx, live(c)) end
      end)
    end,
    edit = function(c)
      c = live(c)
      local target
      for i = #c.thread, 1, -1 do
        local m = c.thread[i]
        if m.author == "user" and (c.status == "PENDING" or m.draft) then target = m break end
      end
      if not target then return notify("posted messages can't be edited") end
      jump(s, c, function()
        local ctx = context.current()
        if not ctx then return end
        float.open_new(ctx, function(body)
          local found = model.find(s.review, c.id)
          if not found or found.deleted then return keep_text(body, "that comment is gone") end
          if not model.edit_message(found, target.id, body) then
            return keep_text(body, "that message was already posted")
          end
          save(s)
        end, target.body)
      end)
    end,
    delete = function(c)
      model.delete(live(c))
      save(s)
    end,
    toggle_resolved = function(c)
      c = live(c)
      if c.status == "RESOLVED" then model.reopen(c) else model.resolve(c) end
      save(s)
    end,
    refresh = function() return s.review end,
  }, { show_resolved = show_resolved == nil and config.options.show_resolved or show_resolved })
end

--- Preview the comment under the cursor.
local function peek_here()
  if float.state then return end
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local info = context.for_buffer(buf)
  local s = info and sessions[info.toplevel]
  if not s then return end
  local c, loc = marks.comment_at(buf, vim.api.nvim_win_get_cursor(win)[1], s.review, s.toplevel)
  if not c then return end
  peek.show({ winid = win, bufnr = buf, line_start = loc.start, line_end = loc.finish }, c)
end

local function refresh_buf(buf)
  for top, s in pairs(sessions) do
    marks.refresh(buf, s.review, top)
  end
end

local function set_keymaps()
  for _, m in ipairs(mapped) do pcall(vim.keymap.del, m[1], m[2]) end
  mapped = {}
  local km = config.options.keymaps
  local function map(mode, lhs, rhs, desc)
    if not lhs then return end
    vim.keymap.set(mode, lhs, rhs, { desc = desc, silent = true })
    table.insert(mapped, { mode, lhs })
  end
  map("n", km.comment, function() M.comment() end, "Review: comment / open thread")
  map("x", km.comment, ":<C-u>'<,'>ReviewComment<CR>", "Review: comment on selection")
  map("n", km.thread, M.thread, "Review: view thread")
  map("n", km.list, function() M.list() end, "Review: list comments")
  map("n", km.submit, M.submit, "Review: post pending comments")
  map("n", km.export, M.export, "Review: export markdown")
  map("n", km.help, function() require("review.help").open() end, "Review: keymap cheat-sheet")
end

function M.setup(opts)
  config.setup(opts)
  local cmd = vim.api.nvim_create_user_command
  cmd("ReviewComment", function(o)
    M.comment(o.range > 0 and { o.line1, o.line2 } or nil)
  end, { range = true, desc = "Review: comment on line/range" })
  cmd("ReviewThread", M.thread, {})
  cmd("ReviewList", function(o) M.list(o.bang or nil) end, { bang = true })
  cmd("ReviewSubmit", M.submit, {})
  cmd("ReviewExport", M.export, {})
  cmd("ReviewNew", M.new, {})
  cmd("ReviewResolve", M.resolve, {})
  cmd("ReviewHelp", function() require("review.help").open() end, {})
  set_keymaps()

  local group = vim.api.nvim_create_augroup("review_nvim", { clear = true })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufWritePost" }, {
    group = group,
    callback = function(a) vim.schedule(function() refresh_buf(a.buf) end) end,
  })
  peek.close()
  if config.options.peek then
    vim.api.nvim_create_autocmd("CursorHold", { group = group, callback = peek_here })
  end
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "DiffviewViewPostLayout", "DiffviewViewEnter" },
    callback = function()
      vim.schedule(function()
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do refresh_buf(vim.api.nvim_win_get_buf(w)) end
      end)
    end,
  })
  -- Load the session for the starting repo so replies show up without commenting first.
  vim.schedule(function()
    local top = git.toplevel(vim.fn.getcwd())
    if top then
      local s = session_for(top)
      marks.refresh_all(s.review, s.toplevel)
    end
  end)
end

-- Test hooks.
M._jump = jump
function M._session(toplevel) return sessions[toplevel] end

--- Test helper: forget all sessions and stop watching.
function M._reset()
  watch.stop()
  sessions = {}
end

return M
