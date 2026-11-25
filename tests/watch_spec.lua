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

describe("watch (multiple files)", function()
  after_each(function() watch.stop() end)

  it("watches two review files independently", function()
    local repo_a, repo_b = h.repo("feat/a"), h.repo("feat/b")
    local ra, pa = store.load_active(repo_a, "feat/a", nil)
    local rb, pb = store.load_active(repo_b, "feat/b", nil)
    store.write(pa, ra)
    store.write(pb, rb)
    local got = {}
    watch.start(pa, function(r) got.a = r end)
    watch.start(pb, function(r) got.b = r end)
    vim.wait(100)
    local da = store.read(pa); da.branch = "A2"; h.write(pa, vim.json.encode(da))
    assert.is_true(vim.wait(1000, function() return got.a ~= nil end, 20))
    assert.equals("A2", got.a.branch)
    assert.is_nil(got.b)
    watch.stop(pa)
    assert.is_nil(watch.watching(pa))
    assert.truthy(watch.watching(pb))
  end)
end)
