-- Real Diffview, driven in a second Neovim so its async layout and events run
-- as they would for a user. Skipped when Diffview isn't installed.
local h = require("review_test_helpers")

local function diffview_dir()
  for _, p in ipairs(vim.api.nvim_list_runtime_paths()) do
    if p:match("diffview%.nvim/?$") and vim.uv.fs_stat(p .. "/lua/diffview") then return p end
  end
end

local dir = diffview_dir()
if not dir then
  -- CI installs Diffview; failing there beats silently skipping these tests.
  assert(vim.env.REVIEW_REQUIRE_DIFFVIEW ~= "1", "diffview.nvim is required but wasn't found")
  describe("diffview", function() pending("diffview.nvim not installed") end)
  return
end

describe("diffview", function()
  local repo, chan
  before_each(function()
    repo = h.repo("feat/x")
    local lines = {}
    for i = 1, 40 do lines[i] = "line " .. i end
    vim.fn.writefile(lines, repo .. "/a.txt")
    h.sh({ "git", "commit", "-qam", "forty" }, repo)
    lines[10] = "changed 10"
    table.insert(lines, 21, "added")
    vim.fn.writefile(lines, repo .. "/a.txt")
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
    chan = vim.fn.jobstart({ vim.v.progpath, "--embed", "--headless", "--clean",
      "--cmd", "set rtp^=" .. root .. " rtp+=" .. dir, "--cmd", "cd " .. repo }, { rpc = true, env = { XDG_STATE_HOME = vim.fn.tempname() } })
    vim.rpcrequest(chan, "nvim_exec_lua", [[
      require("diffview").setup({ use_icons = false })
      require("review").setup({})
      vim.cmd("DiffviewOpen HEAD --imply-local")
    ]], {})
  end)
  after_each(function() vim.fn.jobstop(chan) end)

  local function lua(code, ...) return vim.rpcrequest(chan, "nvim_exec_lua", code, { ... }) end
  local function wait(code, ...)
    local args = { ... }
    return vim.wait(5000, function() return lua(code, unpack(args)) end, 25)
  end
  -- Focus a side of the diff once it shows a.txt and Diffview has settled
  -- (it can still move focus while it finishes loading).
  local function side(which)
    local win
    assert.is_true(vim.wait(5000, function()
      local w = lua([[
        local view = require("diffview.lib").get_current_view()
        local w = view and view.cur_layout and view.cur_layout[...]
        if not (w and w.file and w.file.path == "a.txt" and w.file.bufnr and vim.api.nvim_win_is_valid(w.id)
          and vim.api.nvim_buf_line_count(w.file.bufnr) >= 40) then return 0 end
        vim.api.nvim_set_current_win(w.id)
        return w.id
      ]], which)
      if w == 0 then return false end
      vim.wait(150)
      if lua([[return vim.api.nvim_get_current_win()]]) ~= w then return false end
      win = w
      return true
    end, 50))
    return win
  end
  local function comment(line, text)
    lua([[vim.api.nvim_win_set_cursor(0, { ..., 0 }) require("review").comment()]], line)
    vim.rpcrequest(chan, "nvim_input", text .. "<C-p><Esc>")
    assert.is_true(wait([[local s = require("review.float").state return s ~= nil and s.thread_win ~= nil]]))
    return lua([[local s = require("review.float").state
      return { path = s.ctx.path, side = s.ctx.side, worktree = s.comment.worktree, line = s.comment.line_start,
        anchored = vim.api.nvim_win_get_config(s.input_win).win == s.ctx.winid,
        in_diff = vim.wo[s.ctx.winid].diff, tab = vim.api.nvim_get_current_tabpage() }]])
  end

  it("comments on the new side and keeps the popup in the diff", function()
    side("b")
    local c = comment(10, "why changed")
    assert.same({ "a.txt", "new", true, 10, true, true }, { c.path, c.side, c.worktree, c.line, c.anchored, c.in_diff })
  end)

  it("comments on the old side against a commit", function()
    side("a")
    local c = comment(10, "was fine")
    assert.same({ "a.txt", "old", false, 10 }, { c.path, c.side, c.worktree, c.line })
    assert.equals(40, #lua([[return require("review.float").state.comment.commit]]))
  end)

  it("jumps between comments in a diff pane and from the list", function()
    side("b")
    comment(5, "one")
    lua([[require("review.float").close()]])
    side("b")
    comment(30, "two")
    lua([[require("review.float").close()]])
    side("b")
    lua([[vim.api.nvim_win_set_cursor(0, { 1, 0 })]])
    vim.rpcrequest(chan, "nvim_input", "]r")
    assert.is_true(wait([[return vim.api.nvim_win_get_cursor(0)[1] == 5]]))
    vim.rpcrequest(chan, "nvim_input", "]r")
    assert.is_true(wait([[return vim.api.nvim_win_get_cursor(0)[1] == 30]]))
    -- The picker's jump lands inside the diff, not in a separate file window.
    lua([[
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      package.loaded["review.picker"] = { open = function(review, actions)
        for _, c in ipairs(review.comments) do if c.line_start == 30 then actions.jump(c) end end
      end }
      require("review").list()
    ]])
    assert.is_true(wait([[
      return vim.api.nvim_win_get_cursor(0)[1] == 30 and vim.wo.diff
        and vim.api.nvim_buf_get_name(0):match("^diffview://") == nil
    ]]))
    assert.equals(1, #lua([[return vim.api.nvim_list_tabpages()]]) - 1)
  end)
end)
