local h = require("review_test_helpers")
local review = require("review")
local store = require("review.store")
local marks = require("review.marks")
local float = require("review.float")

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

describe("review (wiring)", function()
  local repo
  before_each(function()
    float.close()
    review._reset()
    vim.cmd("silent! %bwipeout!")
    repo = h.repo("feat/x")
    vim.cmd("cd " .. repo)
    review.setup({})
    vim.cmd("edit " .. repo .. "/a.txt")
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
  end)

  local function current_file()
    return assert(store.active_path(repo, "feat/x"))
  end

  it("comment roundtrip", function()
    review.comment()
    feed("ihi<Esc><CR>")
    local path = current_file()
    assert.truthy(path:match("%-feat%-x%-1%.json$"))
    local r = store.read(path)
    assert.equals(1, #r.comments)
    assert.equals("PENDING", r.comments[1].status)
    assert.equals("hi", r.comments[1].thread[1].body)
    assert.equals("line 3", r.comments[1].snippet)
    local exclude = table.concat(vim.fn.readfile(repo .. "/.git/info/exclude"), "\n")
    assert.truthy(exclude:find(".review/", 1, true))
    assert.equals(1, #vim.api.nvim_buf_get_extmarks(0, marks.ns, 0, -1, {}))

    review.submit()
    assert.equals("POSTED", store.read(path).comments[1].status)
  end)

  it("visual range comment via command", function()
    vim.cmd("2,4ReviewComment")
    feed("irange<C-p>")
    float.close()
    local r = store.read(current_file())
    assert.equals(2, r.comments[1].line_start)
    assert.equals(4, r.comments[1].line_end)
    assert.equals("POSTED", r.comments[1].status)
  end)

  it("comment on existing line opens thread and replies", function()
    review.comment()
    feed("ifirst<C-p>")
    float.close()
    -- agent responds on disk
    local path = current_file()
    local r = store.read(path)
    local now = require("review.model").now()
    table.insert(r.comments[1].thread, { id = "m_agent1", author = "agent", body = "ans", at = now })
    r.comments[1].status = "RESPONDED"
    r.comments[1].updated_at = now
    h.write(path, vim.json.encode(r))
    assert.is_true(vim.wait(1500, function()
      local m = vim.api.nvim_buf_get_extmarks(0, marks.ns, 0, -1, { details = true })[1]
      return m and m[4].virt_text[1][1]:find("agent replied", 1, true) ~= nil
    end, 20))

    review.comment()
    assert.truthy(float.state and float.state.thread_win)
    feed("ifollow up<C-p>")
    float.close()
    local after = store.read(path).comments[1]
    assert.equals(3, #after.thread)
    assert.equals("POSTED", after.status)
  end)

  it("watcher merges disk into memory instead of replacing it", function()
    review.comment()
    feed("ifirst<C-p>")
    float.close()
    local path = current_file()
    vim.wait(100)
    -- file becomes unparseable; the next comment can't be saved but stays in memory
    local good = h.read(path)
    h.write(path, "{oops")
    vim.wait(400)
    local orig = vim.notify
    vim.notify = function() end
    vim.api.nvim_win_set_cursor(0, { 7, 0 })
    review.comment()
    feed("isecond<C-p>")
    float.close()
    vim.notify = orig
    -- someone repairs the file and an agent reply lands at the same time
    local r = vim.json.decode(good)
    local now = require("review.model").now()
    table.insert(r.comments[1].thread, { id = "m_agentx", author = "agent", body = "ans", at = now })
    r.comments[1].status = "RESPONDED"
    r.comments[1].updated_at = now
    h.write(path, vim.json.encode(r))
    assert.is_true(vim.wait(2000, function()
      local d = store.read(path)
      return d and #d.comments == 2
    end, 20), "unsaved comment was not written back after the watcher fired")
    local d = store.read(path)
    assert.equals(2, #d.comments[1].thread)
    assert.equals("RESPONDED", d.comments[1].status)
    assert.equals("second", d.comments[2].thread[1].body)
  end)

  it("records the diff base from the first comment that knows it", function()
    local context = require("review.context")
    local real = context.current
    context.current = function(range)
      local ctx = real(range)
      if ctx then ctx.base = "basesha" end
      return ctx
    end
    vim.wait(50) -- let setup's startup session (no base) load first, as in real use
    review.comment()
    feed("iwith base<C-p>")
    float.close()
    context.current = real
    assert.equals("basesha", store.read(current_file()).base)
  end)

  it("jump falls back to the real file when diffview doesn't list it", function()
    review.comment()
    feed("ijump me<C-p>")
    float.close()
    local s = review._session(repo)
    local c = s.review.comments[1]
    local set_called = false
    local fake_view = {
      adapter = { ctx = { toplevel = repo } },
      files = { iter = function() return function() return nil end end },
      set_file_by_path = function() set_called = true end,
      cur_layout = {},
    }
    local saved = package.loaded["diffview.lib"]
    package.loaded["diffview.lib"] = { get_current_view = function() return fake_view end, views = {} }
    vim.cmd("enew")
    local landed = false
    review._jump(s, c, function() landed = true end)
    package.loaded["diffview.lib"] = saved
    assert.is_true(vim.wait(1500, function() return landed end, 20))
    assert.is_false(set_called)
    assert.equals("a.txt", vim.fn.expand("%:t"))
    assert.equals(3, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("resolve under cursor", function()
    review.comment()
    feed("ix<C-p>")
    float.close()
    review.resolve()
    assert.equals("RESOLVED", store.read(current_file()).comments[1].status)
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(0, marks.ns, 0, -1, {}))
  end)

  it("new starts the next review", function()
    review.comment()
    feed("ix<Esc><CR>")
    review.new()
    assert.truthy(current_file():match("%-feat%-x%-2%.json$"))
    assert.equals(0, #store.read(current_file()).comments)
  end)

  it("keymaps registered and disable-able", function()
    assert.truthy(vim.fn.maparg("<leader>rc", "n") ~= "")
    assert.truthy(vim.fn.maparg("<leader>rc", "x") ~= "")
    review.setup({ keymaps = { export = false } })
    assert.equals("", vim.fn.maparg("<leader>re", "n"))
  end)

  it("list from a popup with a draft returns to the draft", function()
    review.comment()
    feed("ifirst<C-p>")
    float.close()
    for _, from in ipairs({ "input_win", "thread_win" }) do
      review.comment()
      vim.cmd("stopinsert")
      local win, buf = float.state.input_win, float.state.input_buf
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "my draft" })
      vim.api.nvim_set_current_win(float.state[from])
      local opened = false
      local picker = package.loaded["review.picker"]
      package.loaded["review.picker"] = { open = function() opened = true end }
      review.list()
      package.loaded["review.picker"] = picker
      assert.is_false(opened)
      assert.equals(win, vim.api.nvim_get_current_win())
      assert.same({ "my draft" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      float.close()
    end
  end)

  it("keeps reply text when the comment is gone", function()
    review.comment()
    feed("ifirst<C-p>")
    float.close()
    review.comment()
    local path = current_file()
    require("review.model").delete(review._session(repo).review.comments[1])
    vim.fn.setreg('"', "")
    feed("ilate reply<C-p>")
    assert.equals("late reply", vim.fn.getreg('"'))
    assert.equals(1, #store.read(path).comments[1].thread)
  end)

  it("keeps edited text when the comment was posted meanwhile", function()
    review.comment()
    feed("ifirst<Esc><CR>")
    local edit
    local picker = package.loaded["review.picker"]
    package.loaded["review.picker"] = { open = function(_, actions) edit = actions.edit end }
    review.list()
    package.loaded["review.picker"] = picker
    edit(review._session(repo).review.comments[1])
    assert.truthy(float.state)
    review._session(repo).review.comments[1].status = "POSTED"
    vim.api.nvim_buf_set_lines(float.state.input_buf, 0, -1, false, { "changed" })
    vim.fn.setreg('"', "")
    feed("<CR>")
    assert.equals("changed", vim.fn.getreg('"'))
    assert.equals("first", review._session(repo).review.comments[1].thread[1].body)
  end)

  it("shows agent replies in the open thread, without a separate notice", function()
    review.comment()
    feed("ifirst<C-p>")
    assert.truthy(float.state and float.state.thread_win)
    local path = current_file()
    local r = store.read(path)
    local now = require("review.model").now()
    table.insert(r.comments[1].thread, { id = "m_agent1", author = "agent", body = "live answer", at = now })
    r.comments[1].status, r.comments[1].updated_at = "RESPONDED", now
    local said, notify = {}, vim.notify
    vim.notify = function(m) table.insert(said, m) end
    h.write(path, vim.json.encode(r))
    local function text()
      return table.concat(vim.api.nvim_buf_get_lines(float.state.thread_buf, 0, -1, false), "\n")
    end
    vim.wait(1500, function() return text():find("live answer", 1, true) ~= nil end, 20)
    vim.notify = notify
    assert.truthy(text():find(" Agent\n live answer", 1, true))
    assert.same({}, said)
    feed("ithanks<C-p>")
    assert.equals(1, #store.read(path).comments)
    assert.equals(3, #store.read(path).comments[1].thread)
    assert.truthy(text():find(" You\n thanks", 1, true))
    assert.equals("POSTED", store.read(path).comments[1].status)
  end)

  it("list from an open conversation closes it first", function()
    review.comment()
    feed("ifirst<C-p>")
    vim.cmd("stopinsert")
    local picker, opened = package.loaded["review.picker"], false
    package.loaded["review.picker"] = { open = function() opened = true end }
    review.list()
    package.loaded["review.picker"] = picker
    assert.is_true(opened)
    assert.is_nil(float.state)
    assert.equals("a.txt", vim.fn.expand("%:t"))
  end)

  it("resolves the open thread from inside it", function()
    review.comment()
    feed("ifirst<C-p>")
    vim.cmd("stopinsert")
    review.resolve()
    assert.equals("RESOLVED", store.read(current_file()).comments[1].status)
  end)
end)
