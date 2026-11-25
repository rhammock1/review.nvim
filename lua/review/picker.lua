local export = require("review.export")
local model = require("review.model")

local M = {}

local function entry_text(c)
  local first = vim.split((c.thread[1] or {}).body or "", "\n", { plain = true })[1]
  return string.format("%-9s %s:%d  %s", c.status, c.path, c.line_start, first)
end

---@param review review.Review
---@param actions { jump: fun(c), reply: fun(c), edit: fun(c), delete: fun(c), toggle_resolved: fun(c), refresh: fun(): review.Review }
---@param opts? { show_resolved: boolean }
function M.open(review, actions, opts)
  opts = opts or {}
  local ok = pcall(require, "telescope")
  if not ok then
    vim.notify("review: telescope.nvim is required for :ReviewList", vim.log.levels.ERROR)
    return
  end
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local previewers = require("telescope.previewers")
  local conf = require("telescope.config").values
  local tactions = require("telescope.actions")
  local state = require("telescope.actions.state")

  local items = model.visible(review, opts.show_resolved)

  local function run(fn, close_first)
    return function(bufnr)
      local sel = state.get_selected_entry()
      if not sel then return end
      if close_first then tactions.close(bufnr) end
      fn(sel.value, bufnr)
    end
  end

  local function reopen(bufnr, show_resolved)
    tactions.close(bufnr)
    vim.schedule(function()
      M.open(actions.refresh(), actions, { show_resolved = show_resolved })
    end)
  end

  pickers.new({}, {
    prompt_title = string.format("Review %s #%d%s", review.branch, review.number,
      opts.show_resolved and " (all)" or ""),
    finder = finders.new_table({
      results = items,
      entry_maker = function(c)
        local text = entry_text(c)
        return { value = c, display = text, ordinal = text }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      title = "Comment",
      define_preview = function(self, entry)
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, export.render_comment(entry.value))
        vim.bo[self.state.bufnr].filetype = "markdown"
      end,
    }),
    attach_mappings = function(bufnr, map)
      tactions.select_default:replace(run(function(c) actions.jump(c) end, true))
      map({ "i", "n" }, "<C-r>", run(function(c) actions.reply(c) end, true))
      map({ "i", "n" }, "<C-e>", run(function(c) actions.edit(c) end, true))
      map({ "i", "n" }, "<M-d>", run(function(c, b)
        if c.status ~= "PENDING" and vim.fn.confirm("Delete posted comment?", "&Yes\n&No", 2) ~= 1 then return end
        actions.delete(c)
        reopen(b, opts.show_resolved)
      end))
      map({ "i", "n" }, "<M-r>", run(function(c, b)
        actions.toggle_resolved(c)
        reopen(b, opts.show_resolved)
      end))
      map({ "i", "n" }, "<M-h>", function(b) reopen(b, not opts.show_resolved) end)
      return true
    end,
  }):find()
end

return M
