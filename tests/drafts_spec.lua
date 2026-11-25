local h = require("review_test_helpers")
local drafts = require("review.drafts")
local float = require("review.float")
local context = require("review.context")
require("review.config").setup()

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

describe("drafts", function()
  local repo, ctx, calls
  before_each(function()
    float.close()
    vim.cmd("silent! %bwipeout!")
    drafts.dir = vim.fn.tempname()
    repo = h.repo("feat/x")
    vim.cmd("edit " .. repo .. "/a.txt")
    ctx = assert(context.current({ 2, 4 }))
    calls = {}
  end)
  local function submit(body, post) table.insert(calls, { body, post }) end
  local function thread()
    return { id = "c_1", status = "POSTED", path = "a.txt", side = "new", line_start = 2, line_end = 4,
      snippet = "line 2\nline 3\nline 4", thread = { { id = "m_1", author = "user", body = "q", at = "1" } } }
  end
  local function files() return vim.fn.glob(drafts.dir .. "/*", false, true) end
  local function type_text(text)
    vim.api.nvim_buf_set_lines(float.state.input_buf, 0, -1, false, vim.split(text, "\n"))
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = float.state.input_buf })
    drafts.flush()
  end
  -- What a crash leaves behind: windows gone, nothing cleaned up.
  local function crash()
    local s = float.state
    float.state = nil
    pcall(vim.api.nvim_del_augroup_by_id, s.augroup)
    for _, w in ipairs({ s.input_win, s.thread_win }) do pcall(vim.api.nvim_win_close, w, true) end
  end
  local function input() return vim.api.nvim_buf_get_lines(float.state.input_buf, 0, -1, false) end

  it("brings back text after a crash, for the same comment only", function()
    float.open_thread(ctx, thread(), submit)
    vim.cmd("stopinsert")
    type_text("half a\nthought")
    assert.equals(1, #files())
    crash()
    local other = thread()
    other.id = "c_2"
    float.open_thread(ctx, other, submit)
    assert.same({ "" }, input())
    float.close()
    float.open_thread(ctx, thread(), submit)
    assert.same({ "half a", "thought" }, input())
  end)

  it("brings back a new comment for the same lines only", function()
    float.open_new(ctx, submit)
    type_text("new idea")
    crash()
    float.open_new(assert(context.current({ 5, 5 })), submit)
    assert.same({ "" }, input())
    float.close()
    float.open_new(ctx, submit)
    assert.same({ "new idea" }, input())
  end)

  it("keeps repos apart", function()
    float.open_new(ctx, submit)
    type_text("for repo one")
    crash()
    local other = h.repo("feat/x")
    vim.cmd("edit " .. other .. "/a.txt")
    float.open_new(assert(context.current({ 2, 4 })), submit)
    assert.same({ "" }, input())
  end)

  it("is removed when saved, posted, discarded or emptied", function()
    for _, finish in ipairs({ "<CR>", "<C-p>", "q", "empty" }) do
      float.open_new(ctx, submit)
      vim.cmd("stopinsert")
      type_text("text")
      assert.equals(1, #files())
      if finish == "q" then
        local confirm = vim.fn.confirm
        vim.fn.confirm = function() return 1 end
        feed("q")
        vim.fn.confirm = confirm
      elseif finish == "empty" then
        type_text("")
      else
        feed(finish)
      end
      drafts.flush()
      assert.same({}, files())
      float.close()
    end
  end)

  it("is kept when the popup is closed some other way", function()
    float.open_new(ctx, submit)
    vim.cmd("stopinsert")
    type_text("kept")
    vim.cmd("close")
    vim.wait(100, function() return float.state == nil end)
    drafts.flush()
    assert.equals(1, #files())
  end)

  it("ignores and removes old files", function()
    float.open_new(ctx, submit)
    type_text("old")
    crash()
    local f = files()[1]
    local data = vim.json.decode(h.read(f))
    data.at = os.time() - 15 * 86400
    h.write(f, vim.json.encode(data))
    float.open_new(ctx, submit)
    assert.same({ "" }, input())
    assert.same({}, files())
  end)

  it("survives a corrupt file", function()
    float.open_new(ctx, submit)
    type_text("x")
    crash()
    h.write(files()[1], "{oops")
    float.open_new(ctx, submit)
    assert.same({ "" }, input())
  end)
end)
