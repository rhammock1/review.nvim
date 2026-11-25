local export = require("review.export")

local function c(id, status, path, thread, extra)
  local t = { id = id, status = status, path = path, side = "new", commit = "abc", worktree = true,
    line_start = 42, line_end = 48, snippet = "const a = 1;\nconst b = 2;", thread = thread,
    created_at = "", updated_at = "" }
  return vim.tbl_extend("force", t, extra or {})
end

local review = {
  version = 1, branch = "feat/x", number = 1, created_at = "",
  comments = {
    c("c_1", "RESPONDED", "src/sync.js", {
      { id = "m_1", author = "user", body = "why?", at = "1" },
      { id = "m_2", author = "agent", body = "because", at = "2" },
      { id = "m_3", author = "user", body = "ok but", at = "3", draft = true },
    }),
    c("c_2", "RESOLVED", "src/done.js", { { id = "m_4", author = "user", body = "done thing", at = "1" } }),
    c("c_3", "POSTED", "src/gone.js", { { id = "m_5", author = "user", body = "deleted thing", at = "1" } }, { deleted = true }),
    c("c_4", "PENDING", "README", { { id = "m_6", author = "user", body = "one line", at = "1" } }, { line_end = 42, side = "old" }),
  },
}

describe("export", function()
  local out = table.concat(export.render(review), "\n")

  it("header and fence", function()
    assert.truthy(out:find("# Review feat/x #1", 1, true))
    assert.truthy(out:find("## src/sync.js:L42-48 (new) — RESPONDED", 1, true))
    assert.truthy(out:find("\n```js\nconst a = 1;\nconst b = 2;\n```\n", 1, true))
  end)

  it("single line range and no extension", function()
    assert.truthy(out:find("## README:L42 (old) — PENDING", 1, true))
    assert.truthy(out:find("\n```\nconst a", 1, true))
  end)

  it("thread order", function()
    local u, a = out:find("**user:** why?", 1, true), out:find("**agent:** because", 1, true)
    assert.truthy(u and a and u < a)
  end)

  it("draft marked", function()
    assert.truthy(out:find("**user (draft):** ok but", 1, true))
  end)

  it("resolved hidden by default", function()
    assert.falsy(out:find("done thing", 1, true))
    local all = table.concat(export.render(review, { show_resolved = true }), "\n")
    assert.truthy(all:find("done thing", 1, true))
  end)

  it("deleted never shown", function()
    local all = table.concat(export.render(review, { show_resolved = true }), "\n")
    assert.falsy(all:find("deleted thing", 1, true))
  end)

  it("multi-line bodies stay intact", function()
    local r = vim.deepcopy(review)
    r.comments = { c("c_9", "POSTED", "a.lua", { { id = "m", author = "user", body = "l1\nl2", at = "1" } }) }
    local lines = export.render(r)
    assert.truthy(vim.tbl_contains(lines, "**user:** l1"))
    assert.truthy(vim.tbl_contains(lines, "l2"))
  end)
end)
