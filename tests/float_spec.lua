local h = require("review_test_helpers")
local float = require("review.float")
local context = require("review.context")
require("review.config").setup()

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

describe("float", function()
  local repo, ctx, calls
  before_each(function()
    float.close()
    vim.cmd("silent! %bwipeout!")
    repo = h.repo("feat/x")
    vim.cmd("edit " .. repo .. "/a.txt")
    ctx = assert(context.current({ 2, 4 }))
    calls = {}
  end)

  local function submit(body, post) table.insert(calls, { body, post }) end

  it("opens below selection", function()
    float.open_new(ctx, submit)
    local cfg = vim.api.nvim_win_get_config(float.state.input_win)
    assert.equals("win", cfg.relative)
    local title = table.concat(vim.tbl_map(function(t) return t[1] end, cfg.title))
    assert.truthy(title:find("New comment", 1, true))
    assert.truthy(title:find("a.txt L2-4 (new)", 1, true))
    assert.equals("markdown", vim.bo[float.state.input_buf].filetype)
    assert.equals(float.state.input_win, vim.api.nvim_get_current_win())
  end)

  it("save pending", function()
    float.open_new(ctx, submit)
    vim.api.nvim_buf_set_lines(float.state.input_buf, 0, -1, false, { "hello" })
    vim.cmd("stopinsert")
    feed("<CR>")
    assert.same({ { "hello", false } }, calls)
    assert.is_nil(float.state)
  end)

  it("save pending from insert with C-s", function()
    float.open_new(ctx, submit)
    feed("ihello<C-s>")
    assert.same({ { "hello", false } }, calls)
  end)

  it("post", function()
    float.open_new(ctx, submit)
    vim.api.nvim_buf_set_lines(float.state.input_buf, 0, -1, false, { "hello", "world" })
    feed("<C-p>")
    assert.same({ { "hello\nworld", true } }, calls)
  end)

  it("empty body ignored", function()
    float.open_new(ctx, submit)
    vim.cmd("stopinsert")
    feed("<CR>")
    assert.same({}, calls)
    assert.truthy(float.state)
  end)

  it("cancel empty closes without asking", function()
    float.open_new(ctx, submit)
    feed("q")
    assert.is_nil(float.state)
    assert.same({}, calls)
  end)

  it("initial text prefilled", function()
    float.open_new(ctx, submit, "old\ntext")
    assert.same({ "old", "text" }, vim.api.nvim_buf_get_lines(float.state.input_buf, 0, -1, false))
  end)

  it("thread shown", function()
    local comment = { id = "c_1", status = "RESPONDED", path = "a.txt", side = "new", line_start = 2, line_end = 4,
      thread = { { id = "m_1", author = "user", body = "q?", at = "1" },
                 { id = "m_2", author = "agent", body = "answer", at = "2" } } }
    float.open_thread(ctx, comment, submit)
    assert.truthy(vim.api.nvim_win_is_valid(float.state.thread_win))
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float.state.thread_win), 0, -1, false), "\n")
    assert.truthy(text:find(" Agent\n answer", 1, true))
    assert.truthy(text:find(" You\n q?", 1, true))
    assert.is_false(vim.bo[vim.api.nvim_win_get_buf(float.state.thread_win)].modifiable)
    float.close()
    assert.is_nil(float.state)
  end)

  it("leaving the input closes both", function()
    local comment = { id = "c_1", status = "POSTED", path = "a.txt", side = "new", line_start = 2, line_end = 4,
      thread = { { id = "m_1", author = "user", body = "q?", at = "1" } } }
    float.open_thread(ctx, comment, submit)
    local tw = float.state.thread_win
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(ctx.winid)
    assert.is_nil(float.state)
    assert.is_false(vim.api.nvim_win_is_valid(tw))
  end)

  it("leaving the input keeps an unsaved draft open", function()
    float.open_new(ctx, submit)
    local win, buf = float.state.input_win, float.state.input_buf
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "my draft" })
    vim.api.nvim_set_current_win(ctx.winid)
    assert.is_true(vim.api.nvim_win_is_valid(win))
    vim.api.nvim_set_current_win(win)
    feed("<CR>")
    assert.same({ { "my draft", false } }, calls)
    assert.is_nil(float.state)
  end)

  it("opening another popup returns to an unsaved draft instead of dropping it", function()
    float.open_new(ctx, submit)
    local win, buf = float.state.input_win, float.state.input_buf
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "my draft" })
    vim.api.nvim_set_current_win(ctx.winid)
    float.open_new(ctx, submit)
    assert.equals(win, float.state.input_win)
    assert.equals(win, vim.api.nvim_get_current_win())
    assert.same({ "my draft" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("leaving an unchanged edit closes it", function()
    float.open_new(ctx, submit, "old text")
    vim.api.nvim_set_current_win(ctx.winid)
    assert.is_nil(float.state)
  end)

  it("cancel from the thread window asks before dropping a draft", function()
    local comment = { id = "c_1", status = "POSTED", path = "a.txt", side = "new", line_start = 2, line_end = 4,
      thread = { { id = "m_1", author = "user", body = "q?", at = "1" } } }
    float.open_thread(ctx, comment, submit)
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(float.state.input_buf, 0, -1, false, { "reply" })
    vim.api.nvim_set_current_win(float.state.thread_win)
    local confirm, asked = vim.fn.confirm, 0
    vim.fn.confirm = function() asked = asked + 1 return 2 end
    feed("q")
    vim.fn.confirm = confirm
    assert.equals(1, asked)
    assert.truthy(float.state)
  end)

  it("opens a fresh popup after the draft's window was closed some other way", function()
    float.open_new(ctx, submit)
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(float.state.input_buf, 0, -1, false, { "my draft" })
    vim.cmd("close")
    float.open_new(ctx, submit)
    assert.equals(float.state.input_win, vim.api.nvim_get_current_win())
  end)

  it("typing in a draft is fine after its file window closed", function()
    vim.cmd("vsplit")
    ctx = assert(context.current({ 2, 4 }))
    local other = vim.fn.win_getid(vim.fn.winnr("#"))
    float.open_new(ctx, submit)
    local win, buf = float.state.input_win, float.state.input_buf
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "my draft" })
    vim.api.nvim_set_current_win(other)
    vim.api.nvim_win_close(ctx.winid, true)
    assert.is_true(vim.api.nvim_win_is_valid(win))
    vim.api.nvim_set_current_win(win)
    vim.v.errmsg = ""
    pcall(vim.api.nvim_exec_autocmds, "TextChanged", { buffer = buf })
    assert.equals("", vim.v.errmsg)
    feed("<CR>")
    assert.same({ { "my draft", false } }, calls)
  end)

  it("typing a reply is fine after the thread window closed", function()
    local comment = { id = "c_1", status = "POSTED", path = "a.txt", side = "new", line_start = 2, line_end = 4,
      thread = { { id = "m_1", author = "user", body = "q?", at = "1" } } }
    float.open_thread(ctx, comment, submit)
    vim.cmd("stopinsert")
    local buf = float.state.input_buf
    vim.api.nvim_win_close(float.state.thread_win, true)
    vim.v.errmsg = ""
    pcall(vim.api.nvim_exec_autocmds, "TextChanged", { buffer = buf })
    assert.equals("", vim.v.errmsg)
  end)

  it("can't be replaced by another file", function()
    float.open_new(ctx, submit)
    local buf = float.state.input_buf
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "my draft" })
    assert.is_false(pcall(vim.cmd, "edit " .. repo .. "/a.txt"))
    assert.same({ "my draft" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  -- The card ------------------------------------------------------------------

  local function reply_thread(n, extra)
    local t = { { id = "m_0", author = "user", body = "q?", at = "1" } }
    for i = 1, n or 1 do t[#t + 1] = { id = "m_" .. i, author = "agent", body = extra or ("answer " .. i), at = "2" } end
    return { id = "c_1", status = "RESPONDED", path = "a.txt", side = "new", line_start = 2, line_end = 4,
      snippet = "line 2\nline 3\nline 4", thread = t }
  end
  local function flat(chunks) return table.concat(vim.tbl_map(function(c) return c[1] end, chunks or {})) end
  local function conf(win) return vim.api.nvim_win_get_config(win) end
  local function thread_text()
    return table.concat(vim.api.nvim_buf_get_lines(float.state.thread_buf, 0, -1, false), "\n")
  end
  local function marked()
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(ctx.bufnr, vim.api.nvim_create_namespace("review_float"), 0, -1, {})) do
      table.insert(out, m[2] + 1)
    end
    return out
  end
  local function info(win) return vim.fn.getwininfo(win)[1] end
  -- 0-based screen rows a float covers, borders included.
  local function rows(win)
    vim.cmd("redraw")
    local i, b = info(win), conf(win).border
    local top, bottom = b[2] ~= "" and 1 or 0, b[6] ~= "" and 1 or 0
    return i.winrow, i.winrow + top + i.height + bottom - 1
  end

  it("joins the thread and reply box with no gap", function()
    float.open_thread(ctx, reply_thread(), submit)
    local _, thread_end = rows(float.state.thread_win)
    local input_start = rows(float.state.input_win)
    assert.equals(thread_end + 1, input_start)
    assert.equals("├", conf(float.state.thread_win).border[7])
    assert.truthy(flat(conf(float.state.thread_win).footer):find("Reply", 1, true))
    assert.equals(1, conf(float.state.input_win).height)
  end)

  it("never drops the status, whatever the path and width", function()
    for _, cols in ipairs({ 80, 40, 24, 16 }) do
      vim.o.columns = cols
      local c = vim.deepcopy(ctx)
      c.path = ("very/long/directory/"):rep(6) .. "file.ts"
      float.open_thread(c, reply_thread(), submit)
      local text = flat(conf(float.state.thread_win).title)
      assert.truthy(text:find("◆ Replied", 1, true))
      assert.is_true(conf(float.state.thread_win).width <= math.max(cols - 2, 1))
      float.close()
    end
    vim.o.columns = 80
  end)

  it("stays inside a pane with number and sign columns", function()
    vim.cmd("vsplit")
    vim.wo.number, vim.wo.signcolumn = true, "yes:2"
    ctx = assert(context.current({ 2, 4 }))
    float.open_thread(ctx, reply_thread(), submit)
    vim.cmd("redraw")
    local pane, card = info(ctx.winid), info(float.state.thread_win)
    assert.is_true(card.wincol + card.width + 1 <= pane.wincol + pane.width - 1)
  end)

  it("marks the commented lines only while open", function()
    float.open_thread(ctx, reply_thread(), submit)
    assert.same({ 2, 3, 4 }, marked())
    float.close()
    assert.same({}, marked())
  end)

  it("marks where the snippet is now", function()
    vim.api.nvim_buf_set_lines(ctx.bufnr, 0, 0, false, { "new 1", "new 2" })
    float.open_thread(ctx, reply_thread(), submit)
    assert.same({ 4, 5, 6 }, marked())
  end)

  it("shows a placeholder that is never saved", function()
    float.open_new(ctx, submit)
    vim.cmd("stopinsert")
    local ns = vim.api.nvim_create_namespace("review_float")
    local function placeholder() return #vim.api.nvim_buf_get_extmarks(float.state.input_buf, ns, 0, -1, {}) end
    assert.equals(1, placeholder())
    feed("<CR>")
    assert.same({}, calls)
    vim.api.nvim_buf_set_lines(float.state.input_buf, 0, -1, false, { "x" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = float.state.input_buf })
    assert.equals(0, placeholder())
  end)

  it("opens at the newest message and scrolls from the reply box", function()
    float.open_thread(ctx, reply_thread(20), submit)
    vim.cmd("stopinsert")
    local w = float.state.thread_win
    assert.equals(vim.api.nvim_buf_line_count(float.state.thread_buf), info(w).botline)
    assert.truthy(flat(conf(w).footer):find("▲ %d+ more <C%-b>"))
    local top = info(w).topline
    feed("<C-b>")
    assert.is_true(info(w).topline < top)
    assert.equals(float.state.input_win, vim.api.nvim_get_current_win())
    assert.truthy(flat(conf(w).footer):find("▼", 1, true))
    for _ = 1, 20 do feed("<C-b>") end
    assert.equals(1, info(w).topline)
    feed("i<C-f>")
    assert.is_true(info(w).topline > 1)
    for _ = 1, 20 do feed("<C-f>") end
    assert.equals(top, info(w).topline)
  end)

  it("moves between reply and thread", function()
    float.open_thread(ctx, reply_thread(), submit)
    vim.cmd("stopinsert")
    feed("<C-w>k")
    assert.equals(float.state.thread_win, vim.api.nvim_get_current_win())
    feed("<C-w>j")
    assert.equals(float.state.input_win, vim.api.nvim_get_current_win())
  end)

  it("fits on screen when the comment fills or leaves the window", function()
    local many = {}
    for i = 1, 200 do many[i] = "line " .. i end
    vim.api.nvim_buf_set_lines(ctx.bufnr, 0, -1, false, many)
    for _, range in ipairs({ { 1, 200 }, { 150, 160 }, { 20, 20 } }) do
      vim.api.nvim_win_set_cursor(ctx.winid, { 1, 0 })
      local c = reply_thread(20)
      c.line_start, c.line_end = range[1], range[2]
      c.snippet = table.concat(vim.list_slice(many, range[1], range[2]), "\n")
      float.open_thread(ctx, c, submit)
      local a = rows(float.state.thread_win)
      local _, b = rows(float.state.input_win)
      assert.is_true(a >= 1)
      assert.is_true(b <= info(ctx.winid).winrow + info(ctx.winid).height - 1)
      assert.is_true(select(2, rows(float.state.thread_win)) < rows(float.state.input_win))
      float.close()
    end
  end)

  it("wraps again on resize and keeps the draft", function()
    vim.cmd("vsplit")
    ctx = assert(context.current({ 2, 4 }))
    float.open_thread(ctx, reply_thread(1, ("word "):rep(40)), submit)
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(float.state.input_buf, 0, -1, false, { "my draft" })
    local before = vim.api.nvim_buf_line_count(float.state.thread_buf)
    vim.api.nvim_win_set_width(ctx.winid, 24)
    vim.api.nvim_exec_autocmds("WinResized", {})
    vim.wait(500, function() return vim.api.nvim_buf_line_count(float.state.thread_buf) > before end)
    assert.is_true(vim.api.nvim_buf_line_count(float.state.thread_buf) > before)
    assert.is_true(conf(float.state.thread_win).width <= 22)
    assert.same({ "my draft" }, vim.api.nvim_buf_get_lines(float.state.input_buf, 0, -1, false))
  end)

  -- Conversation --------------------------------------------------------------

  local function posting(body, post)
    submit(body, post)
    if not post then return end
    local c = reply_thread(0)
    c.status = "POSTED"
    c.thread[1].body = body
    return c
  end

  it("saving closes, posting stays and becomes the thread", function()
    float.open_new(ctx, posting)
    feed("idraft<Esc><CR>")
    assert.is_nil(float.state)

    float.open_new(ctx, posting)
    feed("ihello<C-p>")
    assert.truthy(float.state and float.state.thread_win)
    assert.truthy(thread_text():find(" You\n hello", 1, true))
    assert.same({ "" }, vim.api.nvim_buf_get_lines(float.state.input_buf, 0, -1, false))
    assert.equals(float.state.input_win, vim.api.nvim_get_current_win())
    assert.truthy(flat(conf(float.state.thread_win).title):find("● Posted", 1, true))
    vim.cmd("stopinsert")
    feed("q")
    assert.is_nil(float.state)
    assert.same({}, marked())
  end)

  it("stays open in the code after posting, until closed", function()
    float.open_new(ctx, posting)
    feed("ihello<C-p>")
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(ctx.winid)
    assert.truthy(float.state)
    -- opening the same comment goes back to it
    local win = float.state.input_win
    float.open_thread(ctx, reply_thread(), submit)
    assert.equals(win, vim.api.nvim_get_current_win())
    -- another comment replaces it
    vim.api.nvim_set_current_win(ctx.winid)
    local other = reply_thread()
    other.id = "c_2"
    float.open_thread(ctx, other, submit)
    assert.equals("c_2", float.state.comment.id)
  end)

  it("closes a conversation when its window shows another file, but not a draft", function()
    vim.fn.writefile({ "b" }, repo .. "/b.txt")
    for _, draft in ipairs({ false, true }) do
      vim.cmd("edit " .. repo .. "/a.txt")
      ctx = assert(context.current({ 2, 4 }))
      float.open_new(ctx, posting)
      feed("ihello<C-p>")
      vim.cmd("stopinsert")
      if draft then vim.api.nvim_buf_set_lines(float.state.input_buf, 0, -1, false, { "more" }) end
      vim.api.nvim_set_current_win(ctx.winid)
      vim.cmd("edit " .. repo .. "/b.txt")
      vim.wait(100, function() return float.state == nil end)
      assert.equals(draft, float.state ~= nil)
      float.close()
    end
  end)

  it("updates the open thread", function()
    local c = reply_thread(1)
    float.open_thread(ctx, c, submit)
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(float.state.input_buf, 0, -1, false, { "typing" })
    local new = vim.deepcopy(c)
    table.insert(new.thread, { id = "m_x", author = "agent", body = "fresh", at = "3" })
    float.update({ comments = { new } })
    assert.truthy(thread_text():find("fresh", 1, true))
    assert.same({ "typing" }, vim.api.nvim_buf_get_lines(float.state.input_buf, 0, -1, false))
    assert.equals(float.state.input_win, vim.api.nvim_get_current_win())
    -- a review without this comment, or with nothing new, changes nothing
    float.update({ comments = {} })
    assert.truthy(thread_text():find("fresh", 1, true))
  end)

  it("follows new messages only when already at the newest", function()
    local c = reply_thread(20)
    float.open_thread(ctx, c, submit)
    vim.cmd("stopinsert")
    local function add(id)
      c = vim.deepcopy(c)
      table.insert(c.thread, { id = id, author = "agent", body = "fresh", at = "3" })
      float.update({ comments = { c } })
    end
    add("m_x")
    assert.equals(vim.api.nvim_buf_line_count(float.state.thread_buf), info(float.state.thread_win).botline)
    for _ = 1, 20 do feed("<C-b>") end
    add("m_y")
    assert.equals(1, info(float.state.thread_win).topline)
    assert.truthy(flat(conf(float.state.thread_win).footer):find("▼", 1, true))
  end)

  it("posting after the code window closed ends cleanly", function()
    vim.cmd("vsplit")
    ctx = assert(context.current({ 2, 4 }))
    local other = vim.fn.win_getid(vim.fn.winnr("#"))
    float.open_new(ctx, posting)
    feed("ihello<Esc>")
    vim.api.nvim_set_current_win(other)
    vim.api.nvim_win_close(ctx.winid, true)
    vim.api.nvim_set_current_win(float.state.input_win)
    feed("<C-p>")
    assert.same({ { "hello", true } }, calls)
    assert.is_nil(float.state)
  end)

  it("isn't showing from another tab", function()
    float.open_new(ctx, posting)
    feed("ihello<C-p>")
    vim.cmd("stopinsert")
    assert.is_true(float.showing("c_1"))
    vim.cmd("tabnew")
    assert.is_false(float.showing("c_1"))
    vim.cmd("tabclose")
  end)

  it("cleans up and keeps the text when its window is closed some other way", function()
    for _, how in ipairs({ "only", "quit", "close" }) do
      vim.cmd("edit " .. repo .. "/a.txt")
      ctx = assert(context.current({ 2, 4 }))
      float.open_new(ctx, posting)
      feed("ihello<C-p>")
      vim.cmd("stopinsert")
      vim.api.nvim_buf_set_lines(float.state.input_buf, 0, -1, false, { "unsent " .. how })
      vim.fn.setreg('"', "")
      if how == "only" then vim.api.nvim_set_current_win(ctx.winid) end
      vim.cmd(how)
      vim.wait(100, function() return float.state == nil end)
      assert.is_nil(float.state)
      assert.same({}, marked())
      assert.equals("unsent " .. how, vim.fn.getreg('"'))
    end
  end)

  it("doesn't touch the register when closed normally", function()
    vim.fn.setreg('"', "mine")
    float.open_new(ctx, posting)
    feed("ihello<Esc><CR>")
    assert.equals("mine", vim.fn.getreg('"'))
  end)

  it("leaves other windows' options alone", function()
    vim.fn.writefile({ "b" }, repo .. "/b.txt")
    vim.o.scrolloff, vim.wo.statuscolumn = 3, ""
    for _, cmd in ipairs({ "vsplit ", "tabnew " }) do
      vim.cmd("edit " .. repo .. "/a.txt")
      ctx = assert(context.current({ 2, 4 }))
      float.open_thread(ctx, reply_thread(), submit)
      vim.cmd("stopinsert")
      vim.cmd(cmd .. repo .. "/b.txt")
      assert.equals("", vim.wo.statuscolumn)
      assert.equals("", vim.wo.winhighlight)
      assert.equals(3, vim.wo.scrolloff)
      assert.is_false(vim.wo.winfixbuf)
      float.close()
      vim.cmd("silent! tabonly | silent! only")
    end
    vim.o.scrolloff = 0
  end)

  it("doesn't move the cursor in the thread when a reply arrives", function()
    local c = reply_thread(20)
    float.open_thread(ctx, c, submit)
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(float.state.thread_win)
    vim.api.nvim_win_set_cursor(0, { 30, 2 })
    local cursor = vim.api.nvim_win_get_cursor(0)
    local top = info(float.state.thread_win).topline
    local new = vim.deepcopy(c)
    table.insert(new.thread, { id = "m_x", author = "agent", body = "fresh", at = "3" })
    float.update({ comments = { new } })
    assert.same(cursor, vim.api.nvim_win_get_cursor(0))
    assert.equals(top, info(float.state.thread_win).topline)
  end)

  it("follows its lines when code above changes", function()
    local c = reply_thread(1)
    float.open_thread(ctx, c, submit)
    vim.api.nvim_buf_set_lines(ctx.bufnr, 0, 0, false, { "new 1", "new 2" })
    local new = vim.deepcopy(c)
    table.insert(new.thread, { id = "m_x", author = "agent", body = "fresh", at = "3" })
    float.update({ comments = { new } })
    assert.same({ 4, 5, 6 }, marked())
  end)

  it("copes with an unknown status", function()
    local c = reply_thread()
    c.status = "odd one"
    float.open_thread(ctx, c, submit)
    vim.cmd("redraw")
    assert.truthy(flat(conf(float.state.thread_win).title):find("odd one", 1, true))
  end)

  -- Scrolling events only fire from Neovim's own input loop, so these run in
  -- a second Neovim driven over RPC.
  local function child(setup)
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
    local chan = vim.fn.jobstart({ vim.v.progpath, "--embed", "--headless", "--clean", "--cmd", "set rtp^=" .. root },
      { rpc = true })
    local function lua(code, ...) return vim.rpcrequest(chan, "nvim_exec_lua", code, { ... }) end
    lua([[
      local repo, setup = ...
      require("review.config").setup()
      vim.cmd("cd " .. repo)
      local many = {}
      for i = 1, 300 do many[i] = "line " .. i end
      vim.fn.writefile(many, repo .. "/a.txt")
      vim.fn.writefile(vim.list_extend({ "extra" }, many), repo .. "/b.txt")
      vim.cmd("edit " .. repo .. "/a.txt")
      if setup == "diff" then
        vim.o.diffopt = "internal,filler,context:400"
        vim.cmd("diffthis | leftabove vsplit " .. repo .. "/b.txt | diffthis | wincmd l")
      end
      vim.api.nvim_win_set_cursor(0, { 150, 0 })
      vim.cmd("normal! zz")
      local float = require("review.float")
      local ctx = require("review.context").current({ 150, 150 })
      float.open_new(ctx, function(body)
        return { id = "c_1", status = "POSTED", path = "a.txt", side = "new", line_start = 150, line_end = 150,
          snippet = "line 150", thread = { { id = "m_1", author = "user", body = body, at = "1" } } }
      end)
      vim.api.nvim_input("hello<C-p><Esc>")
    ]], repo, setup)
    local function wait(code)
      local ok = vim.wait(2000, function() return lua(code) end, 20)
      return ok
    end
    local function hidden()
      return lua([[local s = require("review.float").state
        return s ~= nil and vim.api.nvim_win_get_config(s.input_win).hide == true
          and vim.api.nvim_win_get_config(s.thread_win).hide == true]])
    end
    return { lua = lua, wait = wait, hidden = hidden, input = function(k) vim.rpcrequest(chan, "nvim_input", k) end,
      stop = function() vim.fn.jobstop(chan) end }
  end

  it("hides while its lines are scrolled away and returns with them", function()
    local c = child("plain")
    assert.is_true(c.wait([[return require("review.float").state.thread_win ~= nil]]))
    c.lua([[vim.api.nvim_set_current_win(require("review.float").state.ctx.winid)]])
    assert.is_false(c.hidden())
    c.input("gg")
    assert.is_true(c.wait([[return vim.fn.line("w0") == 1]]))
    assert.is_true(c.wait([[local s = require("review.float").state
      return vim.api.nvim_win_get_config(s.input_win).hide]]))
    assert.is_false(c.lua([[return require("review.float").showing("c_1")]]))
    c.input("150Gzz")
    assert.is_true(c.wait([[local s = require("review.float").state
      return not vim.api.nvim_win_get_config(s.input_win).hide]]))
    -- going to it shows it, whatever the code shows, without overlapping itself
    c.input("gg")
    assert.is_true(c.wait([[return require("review.float").state ~= nil
      and vim.api.nvim_win_get_config(require("review.float").state.input_win).hide]]))
    c.lua([[vim.api.nvim_set_current_win(require("review.float").state.input_win)]])
    assert.is_true(c.wait([[local s = require("review.float").state
      if vim.api.nvim_win_get_config(s.input_win).hide then return false end
      vim.cmd("redraw")
      local t, i = vim.fn.getwininfo(s.thread_win)[1], vim.fn.getwininfo(s.input_win)[1]
      return t.winrow + t.height + 1 <= i.winrow]]))
    c.stop()
  end)

  it("hides when a scroll-bound diff pane drags its lines away", function()
    local c = child("diff")
    assert.is_true(c.wait([[return require("review.float").state.thread_win ~= nil]]))
    c.lua([[vim.cmd("wincmd h")]])
    assert.is_false(c.hidden())
    c.input("gg")
    assert.is_true(c.wait([[return vim.fn.line("w0", require("review.float").state.ctx.winid) <= 2]]))
    assert.is_true(c.wait([[local s = require("review.float").state
      return vim.api.nvim_win_get_config(s.input_win).hide]]))
    c.stop()
  end)

  it("stops saying the agent is working once the mark is too old", function()
    local c = reply_thread(1)
    c.working = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 15 * 60 + 1)
    float.open_thread(ctx, c, submit)
    assert.truthy(thread_text():find("working", 1, true))
    vim.wait(3000, function() return not thread_text():find("working", 1, true) end, 50)
    assert.falsy(thread_text():find("working", 1, true))
  end)
end)
