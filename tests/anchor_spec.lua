local anchor = require("review.anchor")

local function buf(n)
  local t = {}
  for i = 1, n do t[i] = "line " .. i end
  return t
end

describe("anchor", function()
  it("exact at stored line", function()
    local r = anchor.locate(buf(10), { line_start = 4, line_end = 5, snippet = "line 4\nline 5" })
    assert.same({ start = 4, finish = 5, moved = false }, r)
  end)

  it("shifted down", function()
    local lines = buf(10)
    table.insert(lines, 1, "new a"); table.insert(lines, 1, "new b"); table.insert(lines, 1, "new c")
    local r = anchor.locate(lines, { line_start = 4, line_end = 5, snippet = "line 4\nline 5" })
    assert.same({ start = 7, finish = 8, moved = false }, r)
  end)

  it("nearest of duplicates", function()
    local lines = buf(50)
    lines[5] = "dup"; lines[40] = "dup"
    local r = anchor.locate(lines, { line_start = 37, line_end = 37, snippet = "dup" })
    assert.equals(40, r.start)
  end)

  it("tie prefers earlier", function()
    local lines = buf(20)
    lines[5] = "dup"; lines[15] = "dup"
    assert.equals(5, anchor.locate(lines, { line_start = 10, line_end = 10, snippet = "dup" }).start)
  end)

  it("missing snippet falls back", function()
    local r = anchor.locate(buf(10), { line_start = 3, line_end = 4, snippet = "gone\nforever" })
    assert.same({ start = 3, finish = 4, moved = true }, r)
  end)

  it("clamps past EOF", function()
    local r = anchor.locate(buf(10), { line_start = 999, line_end = 1000, snippet = "nope" })
    assert.is_true(r.finish <= 10)
    assert.is_true(r.start <= r.finish)
    assert.is_true(r.moved)
  end)

  it("empty snippet falls back", function()
    local r = anchor.locate(buf(10), { line_start = 2, line_end = 2, snippet = "" })
    assert.same({ start = 2, finish = 2, moved = false }, r)
  end)
end)
