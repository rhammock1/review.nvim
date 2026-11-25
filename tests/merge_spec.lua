local merge = require("review.merge").merge

local function msg(id, author, body, at, draft)
  return { id = id, author = author, body = body, at = at, draft = draft }
end

local function comment(id, status, updated, thread)
  return { id = id, status = status, path = "a.js", side = "new", commit = "abc",
           worktree = true, line_start = 1, line_end = 1, snippet = "x",
           created_at = "2026-11-25T10:00:00Z", updated_at = updated, thread = thread }
end

local function review(comments)
  return { version = 1, branch = "feat/x", number = 1,
           created_at = "2026-11-25T10:00:00Z", comments = comments }
end

describe("merge", function()
  it("nil disk returns copy of mine", function()
    local mine = review({ comment("c_1", "PENDING", "2026-11-25T10:00:00Z",
      { msg("m_1", "user", "hi", "2026-11-25T10:00:00Z") }) })
    local out = merge(nil, mine)
    assert.same(mine, out)
    assert.are_not.equal(mine, out)
  end)

  it("agent reply survives", function()
    local u = msg("m_1", "user", "why?", "2026-11-25T10:00:00Z")
    local mine = review({ comment("c_1", "POSTED", "2026-11-25T10:00:00Z", { u }) })
    local disk = review({ comment("c_1", "RESPONDED", "2026-11-25T10:05:00Z",
      { u, msg("m_2", "agent", "because", "2026-11-25T10:05:00Z") }) })
    local out = merge(disk, mine)
    assert.equals("RESPONDED", out.comments[1].status)
    assert.equals(2, #out.comments[1].thread)
    assert.equals("because", out.comments[1].thread[2].body)
  end)

  it("user reply after agent wins status", function()
    local u = msg("m_1", "user", "why?", "2026-11-25T10:00:00Z")
    local a = msg("m_2", "agent", "because", "2026-11-25T10:05:00Z")
    local disk = review({ comment("c_1", "RESPONDED", "2026-11-25T10:05:00Z", { u, a }) })
    local mine = review({ comment("c_1", "POSTED", "2026-11-25T10:06:00Z",
      { u, msg("m_3", "user", "and null?", "2026-11-25T10:06:00Z") }) })
    local out = merge(disk, mine)
    assert.equals("POSTED", out.comments[1].status)
    local ids = vim.tbl_map(function(m) return m.id end, out.comments[1].thread)
    assert.same({ "m_1", "m_2", "m_3" }, ids)
  end)

  it("tombstone not resurrected", function()
    local u = msg("m_1", "user", "hi", "2026-11-25T10:00:00Z")
    local disk = review({ comment("c_1", "POSTED", "2026-11-25T10:09:00Z", { u }) })
    local c = comment("c_1", "POSTED", "2026-11-25T10:01:00Z", { u })
    c.deleted = true
    local out = merge(disk, review({ c }))
    assert.is_true(out.comments[1].deleted)
  end)

  it("interleaved writes keep both sides", function()
    local u1 = msg("m_1", "user", "a?", "2026-11-25T10:00:00Z")
    local disk = review({ comment("c_a", "RESPONDED", "2026-11-25T10:05:00Z",
      { u1, msg("m_2", "agent", "ans", "2026-11-25T10:05:00Z") }) })
    local mine = review({
      comment("c_a", "POSTED", "2026-11-25T10:00:00Z", { u1, msg("m_3", "user", "more", "2026-11-25T10:04:00Z", true) }),
      comment("c_b", "PENDING", "2026-11-25T10:04:00Z", { msg("m_4", "user", "b", "2026-11-25T10:04:00Z") }),
    })
    local out = merge(disk, mine)
    assert.equals(2, #out.comments)
    local ids = vim.tbl_map(function(m) return m.id end, out.comments[1].thread)
    assert.same({ "m_1", "m_3", "m_2" }, ids)
    assert.equals("c_b", out.comments[2].id)
  end)

  it("disk-only comments are kept after mine", function()
    local disk = review({ comment("c_z", "POSTED", "2026-11-25T10:00:00Z", { msg("m_9", "user", "z", "2026-11-25T10:00:00Z") }) })
    local mine = review({ comment("c_a", "PENDING", "2026-11-25T10:00:00Z", { msg("m_1", "user", "a", "2026-11-25T10:00:00Z") }) })
    local out = merge(disk, mine)
    assert.same({ "c_a", "c_z" }, vim.tbl_map(function(c) return c.id end, out.comments))
  end)

  it("tie: agent RESPONDED after last user message wins", function()
    local u = msg("m_1", "user", "why?", "2026-11-25T10:00:00Z")
    local mine = review({ comment("c_1", "POSTED", "2026-11-25T10:00:00Z", { u }) })
    local disk = review({ comment("c_1", "RESPONDED", "2026-11-25T10:00:00Z",
      { u, msg("m_2", "agent", "because", "2026-11-25T10:00:00Z") }) })
    assert.equals("RESPONDED", merge(disk, mine).comments[1].status)
  end)

  it("tie: user reply after agent keeps POSTED", function()
    local u = msg("m_1", "user", "why?", "2026-11-25T10:00:00Z")
    local a = msg("m_2", "agent", "because", "2026-11-25T10:00:00Z")
    local disk = review({ comment("c_1", "RESPONDED", "2026-11-25T10:00:00Z", { u, a }) })
    local mine = review({ comment("c_1", "POSTED", "2026-11-25T10:00:00Z",
      { u, a, msg("m_3", "user", "more", "2026-11-25T10:00:00Z") }) })
    assert.equals("POSTED", merge(disk, mine).comments[1].status)
  end)

  it("agent cannot clobber user text", function()
    local disk = review({ comment("c_1", "POSTED", "2026-11-25T10:00:00Z",
      { msg("m_1", "user", "TAMPERED", "2026-11-25T10:00:00Z") }) })
    local mine = review({ comment("c_1", "POSTED", "2026-11-25T10:00:00Z",
      { msg("m_1", "user", "original", "2026-11-25T10:00:00Z") }) })
    assert.equals("original", merge(disk, mine).comments[1].thread[1].body)
  end)
end)
