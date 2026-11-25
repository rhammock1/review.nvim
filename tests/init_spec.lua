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
    local r = store.read(current_file())
    assert.equals(2, r.comments[1].line_start)
    assert.equals(4, r.comments[1].line_end)
    assert.equals("POSTED", r.comments[1].status)
  end)

  it("comment on existing line opens thread and replies", function()
    review.comment()
    feed("ifirst<C-p>")
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
    local after = store.read(path).comments[1]
    assert.equals(3, #after.thread)
    assert.equals("POSTED", after.status)
  end)

  it("resolve under cursor", function()
    review.comment()
    feed("ix<C-p>")
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
end)
