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
end)
