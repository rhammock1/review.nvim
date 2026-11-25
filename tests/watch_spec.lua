local h = require("review_test_helpers")
local watch = require("review.watch")
local store = require("review.store")
local model = require("review.model")
require("review.config").setup()

describe("watch", function()
  local repo, path, review
  before_each(function()
    repo = h.repo("feat/x")
    review, path = store.load_active(repo, "feat/x", nil)
    assert.is_true(store.write(path, review))
  end)
  after_each(function() watch.stop() end)

  it("fires on external write", function()
    local got
    watch.start(path, function(r) got = r end)
    vim.wait(100)
    local disk = store.read(path)
    disk.branch = "changed"
    h.write(path, vim.json.encode(disk))
    assert.is_true(vim.wait(1000, function() return got ~= nil end, 20))
    assert.equals("changed", got.branch)
  end)

  it("fires on atomic rename by another writer", function()
    local got
    watch.start(path, function(r) got = r end)
    vim.wait(100)
    local disk = store.read(path)
    disk.branch = "renamed"
    h.write(path .. ".tmp", vim.json.encode(disk))
    os.rename(path .. ".tmp", path)
    assert.is_true(vim.wait(1000, function() return got ~= nil end, 20))
    assert.equals("renamed", got.branch)
  end)

  it("ignores own write", function()
    local calls = 0
    watch.start(path, function() calls = calls + 1 end)
    vim.wait(100)
    review.comments = { model.new_comment({ path = "a.txt", side = "new", commit = "x", worktree = true,
      line_start = 1, line_end = 1, snippet = "line 1" }, "hi", false) }
    assert.is_true(store.write(path, review))
    vim.wait(500)
    assert.equals(0, calls)
  end)

  it("ignores unparseable content", function()
    local calls = 0
    watch.start(path, function() calls = calls + 1 end)
    vim.wait(100)
    h.write(path, "{half")
    vim.wait(500)
    assert.equals(0, calls)
  end)
end)
