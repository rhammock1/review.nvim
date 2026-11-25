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
    assert.truthy(title:find("a.txt  L2-4 (new)", 1, true))
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
    assert.truthy(text:find("agent ▸ answer", 1, true))
    assert.truthy(text:find("user ▸ q?", 1, true))
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
end)
