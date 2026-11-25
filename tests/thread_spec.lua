local thread = require("review.thread")

describe("thread.wrap", function()
  it("wraps at spaces and keeps file references whole", function()
    assert.same({ "typed as unknown", "(types.ts:93), so", "it casts" },
      thread.wrap("typed as unknown (types.ts:93), so it casts", 17))
  end)

  it("keeps paragraphs and inner spacing", function()
    assert.same({ "a  b", "", "c" }, thread.wrap("a  b\n\nc", 20))
  end)

  it("keeps fenced code and tables as written", function()
    local s = "```lua\nlocal  x = 'a long line of code here'\n\n```\n| a | a long table row here |\nafter the fence"
    assert.same({ "```lua", "local  x = 'a long line of code here'", "", "```", "| a | a long table row here |",
      "after the", "fence" }, thread.wrap(s, 10))
  end)

  it("only ends a fence with a matching marker", function()
    assert.same({ "````", "```", "one two three", "````", "one two", "three" },
      thread.wrap("````\n```\none two three\n````\none two three", 7))
  end)

  it("hangs list items and quotes", function()
    assert.same({ "- one two", "  three" }, thread.wrap("- one two three", 10))
    assert.same({ "10. one", "    two" }, thread.wrap("10. one two", 8))
    assert.same({ "> one two", "> three" }, thread.wrap("> one two three", 10))
  end)

  it("keeps a word that is too long", function()
    assert.same({ "a", "abcdefghijkl", "b" }, thread.wrap("a abcdefghijkl b", 5))
  end)

  it("handles carriage returns, wide characters and empty text", function()
    assert.same({ "a", "b" }, thread.wrap("a\r\nb\r", 10))
    assert.same({ "日本", "語語" }, thread.wrap("日本 語語", 5))
    assert.same({ "" }, thread.wrap("", 10))
  end)
end)

describe("thread.ago", function()
  local now = 1795641000 -- 2026-11-25T21:10:00Z
  it("describes ages", function()
    assert.equals("just now", thread.ago("2026-11-25T21:09:30Z", now))
    assert.equals("just now", thread.ago("2026-11-25T21:15:00Z", now))
    assert.equals("4m ago", thread.ago("2026-11-25T21:06:00Z", now))
    assert.equals("3h ago", thread.ago("2026-11-25T18:00:00Z", now))
    assert.equals("2d ago", thread.ago("2026-11-23T20:00:00Z", now))
    assert.equals("2026-10-01", thread.ago("2026-10-01T00:00:00Z", now))
  end)

  it("is empty when it can't tell", function()
    assert.equals("", thread.ago(nil, now))
    assert.equals("", thread.ago("1", now))
    assert.equals("", thread.ago(5, now))
  end)
end)

describe("thread.render", function()
  local now = 1795641000
  local function comment(msgs) return { thread = msgs } end
  local function texts(marks, group, lines)
    local out = {}
    for _, m in ipairs(marks) do
      if m.opts.hl_group == group then table.insert(out, lines[m.row + 1]:sub(m.col + 1, m.opts.end_col)) end
    end
    return out
  end

  it("names, times and spacing", function()
    local lines, marks = thread.render(comment({
      { id = "1", author = "user", body = "Why?", at = "2026-11-25T21:06:00Z" },
      { id = "2", author = "agent", body = "Because.", at = "2026-11-25T21:09:50Z" },
      { id = "3", author = "user", body = "ok", at = "2026-11-25T21:10:00Z", draft = true },
    }), 40, now)
    assert.same({ " You", " Why?", "", " Agent", " Because.", "", " You (draft)", " ok" }, lines)
    local times = {}
    for _, m in ipairs(marks) do
      if m.opts.virt_text then table.insert(times, vim.trim(m.opts.virt_text[1][1])) end
    end
    assert.same({ "4m ago", "just now", "just now" }, times)
  end)

  it("never indents prose into a code block", function()
    local lines = thread.render(comment({ { id = "1", author = "agent", body = "one\n\ntwo\n\nthree" } }), 40, now)
    for _, l in ipairs(lines) do assert.is_nil(l:match("^    ")) end
  end)

  it("marks file references but not addresses", function()
    local lines, marks = thread.render(comment({ { id = "1", author = "agent",
      body = "see src/a-b.ts:48 and (types.ts:93-95), not http://example.com:80 or 10:30" } }), 200, now)
    assert.same({ "src/a-b.ts:48", "types.ts:93-95" }, texts(marks, "ReviewRef", lines))
  end)

  it("survives incomplete messages", function()
    local lines = thread.render(comment({ { id = "1", author = "agent" }, { id = "2", body = "hi" } }), 40, now)
    assert.same({ " Agent", "", "", " Unknown", " hi" }, lines)
    assert.same({ "" }, (thread.render({}, 40, now)))
  end)

  it("stays within the width", function()
    local lines = thread.render(comment({ { id = "1", author = "agent", body = ("word "):rep(60) } }), 30, now)
    for _, l in ipairs(lines) do assert.is_true(vim.fn.strdisplaywidth(l) <= 29) end
  end)
end)
