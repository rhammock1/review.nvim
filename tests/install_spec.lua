local h = require("review_test_helpers")
local install = require("review.install")
vim.cmd("runtime plugin/review.lua")

describe("install", function()
  local home, target, notes, old_notify, old_env
  before_each(function()
    home = vim.fn.tempname()
    vim.fn.mkdir(home, "p")
    home = vim.uv.fs_realpath(home)
    old_env = vim.env.CLAUDE_CONFIG_DIR
    vim.env.CLAUDE_CONFIG_DIR = home .. "/claude"
    target = home .. "/claude/skills/review-comments"
    notes, old_notify = {}, vim.notify
    vim.notify = function(msg, level) table.insert(notes, { msg, level }) end
  end)
  after_each(function()
    vim.notify = old_notify
    vim.env.CLAUDE_CONFIG_DIR = old_env
  end)

  local function errors()
    return vim.tbl_filter(function(n) return n[2] == vim.log.levels.ERROR end, notes)
  end

  it("links the skill, with a runnable script inside", function()
    assert.is_true(install.run("claude"))
    assert.equals("link", vim.uv.fs_lstat(target).type)
    assert.truthy(h.read(target .. "/SKILL.md"):find("name: review-comments", 1, true))
    assert.equals(1, vim.fn.executable(target .. "/scripts/review-watch"))
    assert.same({}, errors())
  end)

  it("is safe to run again", function()
    assert.is_true(install.run("claude"))
    local before = vim.uv.fs_readlink(target)
    assert.is_true(install.run("claude"))
    assert.equals(before, vim.uv.fs_readlink(target))
    assert.same({}, errors())
  end)

  it("accepts an existing link that resolves to the same skill", function()
    vim.fn.mkdir(vim.fs.dirname(target), "p")
    local alias = home .. "/alias"
    assert(vim.uv.fs_symlink(install.source("claude"), alias))
    assert(vim.uv.fs_symlink(alias, target))
    assert.is_true(install.run("claude"))
    assert.equals(alias, vim.uv.fs_readlink(target))
  end)

  it("leaves a real directory alone", function()
    vim.fn.mkdir(target, "p")
    h.write(target .. "/SKILL.md", "mine")
    assert.is_false(install.run("claude"))
    assert.equals("directory", vim.uv.fs_lstat(target).type)
    assert.equals("mine", h.read(target .. "/SKILL.md"))
    assert.equals(1, #errors())
  end)

  it("leaves a link to somewhere else, or a dangling link, alone", function()
    vim.fn.mkdir(vim.fs.dirname(target), "p")
    assert(vim.uv.fs_symlink(home .. "/nowhere", target))
    assert.is_false(install.run("claude"))
    assert.equals(home .. "/nowhere", vim.uv.fs_readlink(target))
    assert.equals(1, #errors())
  end)

  it("rejects a missing or unknown agent", function()
    for _, agent in ipairs({ "", "nope" }) do
      notes = {}
      assert.is_false(install.run(agent))
      assert.equals(1, #errors())
      assert.truthy(errors()[1][1]:find("claude", 1, true))
    end
    assert.is_nil(vim.uv.fs_lstat(home .. "/claude"))
  end)

  it(":ReviewInstall works without setup() and completes agents", function()
    vim.cmd("ReviewInstall claude")
    assert.equals("link", vim.uv.fs_lstat(target).type)
    assert.same({ "claude" }, vim.fn.getcompletion("ReviewInstall ", "cmdline"))
  end)
end)
