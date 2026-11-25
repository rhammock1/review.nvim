local help = require("review.help")
local config = require("review.config")

local function text() return table.concat(help.lines(), "\n") end

describe("help", function()
  before_each(function() config.setup() end)

  it("lists global keymaps with what they do", function()
    local t = text()
    assert.truthy(t:find("<leader>rc", 1, true))
    assert.truthy(t:find("New comment", 1, true))
    assert.truthy(t:find("<leader>rs", 1, true))
    assert.truthy(t:find("<leader>r?", 1, true))
  end)

  it("lists popup and picker keys and signs", function()
    local t = text()
    assert.truthy(t:find("<C-p>", 1, true))
    assert.truthy(t:find("<M-h>", 1, true))
    assert.truthy(t:find("◆", 1, true))
  end)

  it("reflects remapped and disabled keys", function()
    config.setup({ keymaps = { comment = "<leader>xx", export = false }, float_keymaps = { post = { "<C-g>" } } })
    local t = text()
    assert.truthy(t:find("<leader>xx", 1, true))
    assert.falsy(t:find("<leader>rc", 1, true))
    assert.falsy(t:find("<leader>re", 1, true))
    assert.truthy(t:find(":ReviewExport", 1, true))
    assert.truthy(t:find("<C-g>", 1, true))
  end)

  it("opens a closable float", function()
    local win = help.open()
    assert.equals("editor", vim.api.nvim_win_get_config(win).relative)
    assert.is_false(vim.bo[vim.api.nvim_win_get_buf(win)].modifiable)
    vim.api.nvim_feedkeys("q", "x", false)
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)

  it("keeps a comment draft open underneath", function()
    local float = require("review.float")
    vim.cmd("enew")
    float.open_new({
      path = "a.txt", side = "new", line_start = 1, line_end = 1,
      bufnr = vim.api.nvim_get_current_buf(), winid = vim.api.nvim_get_current_win(),
    }, function() end)
    vim.cmd("stopinsert")
    local input_win, input_buf = float.state.input_win, float.state.input_buf
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "my draft" })

    local win = help.open()
    assert.is_true(vim.api.nvim_win_is_valid(win))
    assert.equals(win, vim.api.nvim_get_current_win())
    assert.is_true(vim.api.nvim_win_is_valid(input_win))

    -- Opening it again reuses the window, so closing still returns to the draft.
    assert.equals(win, help.open())

    vim.api.nvim_feedkeys("q", "x", false)
    assert.is_false(vim.api.nvim_win_is_valid(win))
    assert.equals(input_win, vim.api.nvim_get_current_win())
    assert.same({ "my draft" }, vim.api.nvim_buf_get_lines(input_buf, 0, -1, false))
    float.close()
  end)

  it("describes the save key according to post_on_submit", function()
    assert.truthy(text():find("Save as draft and close", 1, true))
    config.setup({ post_on_submit = true })
    assert.falsy(text():find("Save as draft and close", 1, true))
  end)

  it("omits float keys and signs that are turned off", function()
    config.setup({ float_keymaps = { save_insert = {}, post = false }, signs = { POSTED = false } })
    local t = text()
    assert.falsy(t:find("(insert)", 1, true))
    assert.falsy(t:find("Post now", 1, true))
    assert.falsy(t:find("posted", 1, true))
    assert.truthy(t:find("◆ responded", 1, true))
    config.setup({ float_keymaps = false, signs = false, keymaps = false })
    t = text()
    for _, gone in ipairs({ "(normal)", "(insert)", "Post now", "Scroll the thread" }) do
      assert.falsy(t:find(gone, 1, true))
    end
    assert.falsy(t:find("pending  ", 1, true))
    assert.truthy(t:find(":ReviewComment", 1, true))
  end)

  it("only claims a visual mapping for comments", function()
    local t = text()
    assert.falsy(t:find("Anywhere (on a line or visual selection)", 1, true))
    assert.truthy(t:find("New comment on a line or selection", 1, true))
  end)

  it("opens on a tiny screen and wraps at words", function()
    local lines, cols = vim.o.lines, vim.o.columns
    for _, size in ipairs({ { 3, 12 }, { 4, 20 }, { 10, 40 } }) do
      vim.o.lines, vim.o.columns = size[1], size[2]
      local win = help.open()
      assert.is_true(vim.wo[win].linebreak)
      vim.api.nvim_win_close(win, true)
    end
    vim.o.lines, vim.o.columns = lines, cols
  end)

  it("returns to insert mode when opened with <C-o> from insert", function()
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
    local chan = vim.fn.jobstart({ vim.v.progpath, "--embed", "--headless", "--clean",
      "--cmd", "set rtp^=" .. root, "-c", "lua require('review').setup()" }, { rpc = true })
    local function req(...) return vim.rpcrequest(chan, ...) end
    local function mode() return req("nvim_get_mode").mode end
    req("nvim_input", "iabc<C-o>:ReviewHelp<CR>")
    vim.wait(1000, function() return #req("nvim_list_wins") == 2 and mode() == "n" end)
    assert.equals(2, #req("nvim_list_wins"))
    assert.equals("n", mode())
    req("nvim_input", "q")
    vim.wait(1000, function() return #req("nvim_list_wins") == 1 and mode() == "i" end)
    assert.equals(1, #req("nvim_list_wins"))
    assert.equals("i", mode())
    req("nvim_input", "d")
    vim.wait(1000, function() return req("nvim_get_current_line") == "abcd" end)
    assert.equals("abcd", req("nvim_get_current_line"))
    vim.fn.jobstop(chan)
  end)

  it("covers the popup's conversation keys", function()
    local t = text()
    assert.truthy(t:find("Save as draft and close", 1, true))
    assert.truthy(t:find("<C-w>k  <C-w>j", 1, true))
    assert.truthy(t:find("Resolve the comment under the cursor, or the open thread", 1, true))
  end)
end)
