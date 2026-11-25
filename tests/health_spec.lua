local install = require("review.install")
local health = require("review.health")

describe("health", function()
  local home, old_env, old_exec, missing
  before_each(function()
    home = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(home, "p")
    home = vim.uv.fs_realpath(home)
    old_env = vim.env.CLAUDE_CONFIG_DIR
    vim.env.CLAUDE_CONFIG_DIR = home .. "/claude"
    missing = {}
    old_exec = vim.fn.executable
    vim.fn.executable = function(name) return missing[name] and 0 or old_exec(name) end
  end)
  after_each(function()
    vim.env.CLAUDE_CONFIG_DIR = old_env
    vim.fn.executable = old_exec
  end)

  -- Run the check and collect what it reported, by level.
  local function report()
    local out = { ok = {}, info = {}, warn = {}, error = {} }
    local real = vim.health
    local fake = { start = function() end }
    for level in pairs(out) do
      fake[level] = function(msg) table.insert(out[level], msg) end
    end
    vim.health = fake
    local ok, err = pcall(health.check)
    vim.health = real
    assert(ok, err)
    return out
  end
  local function has(list, text)
    for _, m in ipairs(list) do if m:find(text, 1, true) then return true end end
    return false
  end

  it("reports a working setup", function()
    require("review").setup({})
    install.run("claude")
    local r = report()
    assert.same({}, r.error)
    assert.is_true(has(r.ok, "Neovim"))
    assert.is_true(has(r.ok, "git"))
    assert.is_true(has(r.ok, "claude"))
  end)

  it("explains each missing tool", function()
    missing = { git = true, jq = true }
    local r = report()
    assert.is_true(has(r.error, "git"))
    assert.is_true(has(r.warn, "jq"))
  end)

  it("says how to install the agent side", function()
    local r = report()
    assert.is_true(has(r.info, ":ReviewInstall claude"))
  end)

  it("names what is in the way of the skill", function()
    vim.fn.mkdir(home .. "/claude/skills/review-comments", "p")
    local r = report()
    assert.is_true(has(r.warn, home .. "/claude/skills/review-comments"))
  end)

  it("warns when setup() hasn't run", function()
    package.loaded["review"] = nil
    require("review.config").configured = nil
    local r = report()
    assert.is_true(has(r.warn, "setup()"))
  end)
end)
