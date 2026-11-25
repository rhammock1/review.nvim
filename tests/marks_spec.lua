local h = require("review_test_helpers")
local marks = require("review.marks")
local model = require("review.model")
local config = require("review.config")

local function comment(status, l1, l2, snippet, thread)
  return { id = "c_" .. status:lower(), status = status, path = "a.txt", side = "new", commit = "x", worktree = true,
    line_start = l1, line_end = l2, snippet = snippet, created_at = "", updated_at = "",
    thread = thread or { { id = "m_1", author = "user", body = "q", at = "1" } } }
end

describe("marks", function()
  local repo, buf
  before_each(function()
    config.setup()
    vim.cmd("silent! %bwipeout!")
    repo = h.repo("feat/x")
    vim.cmd("edit " .. repo .. "/a.txt")
    buf = vim.api.nvim_get_current_buf()
  end)

  local function extmarks()
    return vim.api.nvim_buf_get_extmarks(buf, marks.ns, 0, -1, { details = true })
  end

  it("places sign at located line", function()
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new 1", "new 2" })
    local r = model.new_review("feat/x", nil, 1)
    r.comments = { comment("POSTED", 4, 4, "line 4") }
    marks.refresh(buf, r)
    local ms = extmarks()
    assert.equals(1, #ms)
    assert.equals(5, ms[1][2]) -- 0-based row of shifted line 4 (now line 6)
    assert.equals("●", vim.trim(ms[1][4].sign_text))
    assert.equals("💬 1", ms[1][4].virt_text[1][1])
  end)

  it("agent replied and moved labels", function()
    local r = model.new_review("feat/x", nil, 1)
    r.comments = { comment("RESPONDED", 3, 3, "gone", {
      { id = "m_1", author = "user", body = "q", at = "1" },
      { id = "m_2", author = "agent", body = "a", at = "2" } }) }
    marks.refresh(buf, r)
    local ms = extmarks()
    assert.equals(2, ms[1][2])
    assert.equals("💬 2 · agent replied · moved?", ms[1][4].virt_text[1][1])
  end)

  it("resolved hidden", function()
    local r = model.new_review("feat/x", nil, 1)
    r.comments = { comment("RESOLVED", 2, 2, "line 2") }
    marks.refresh(buf, r)
    assert.equals(0, #extmarks())
  end)

  it("ignores other paths and old side", function()
    local r = model.new_review("feat/x", nil, 1)
    local other = comment("POSTED", 2, 2, "line 2"); other.path = "b.txt"
    local old = comment("PENDING", 2, 2, "line 2"); old.side = "old"
    r.comments = { other, old }
    marks.refresh(buf, r)
    assert.equals(0, #extmarks())
  end)

  it("refresh clears previous marks", function()
    local r = model.new_review("feat/x", nil, 1)
    r.comments = { comment("POSTED", 2, 2, "line 2") }
    marks.refresh(buf, r)
    marks.refresh(buf, r)
    assert.equals(1, #extmarks())
  end)

  it("comment_at", function()
    local r = model.new_review("feat/x", nil, 1)
    local c = comment("POSTED", 3, 5, "line 3\nline 4\nline 5")
    r.comments = { c }
    assert.equals(c, marks.comment_at(buf, 4, r))
    assert.is_nil(marks.comment_at(buf, 6, r))
  end)

  it("says when the agent is working", function()
    local r = model.new_review("feat/x", nil, 1)
    local c = comment("POSTED", 3, 3, "line 3")
    c.working = model.now()
    r.comments = { c }
    marks.refresh(buf, r)
    assert.truthy(extmarks()[1][4].virt_text[1][1]:find("agent working", 1, true))
    c.working = "2000-01-01T00:00:00Z"
    marks.refresh(buf, r)
    assert.falsy(extmarks()[1][4].virt_text[1][1]:find("agent working", 1, true))
  end)
end)
