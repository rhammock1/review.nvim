local config = require("review.config")
local model = require("review.model")

local M = {}

local function range(c)
  if c.line_end and c.line_end ~= c.line_start then
    return string.format("L%d-%d", c.line_start, c.line_end)
  end
  return "L" .. c.line_start
end
M.range = range

local function fence_for(snippet)
  local fence = "```"
  while snippet:find(fence, 1, true) do fence = fence .. "`" end
  return fence
end

--- Markdown lines for one comment (no trailing blank line).
function M.render_comment(c)
  local out = {}
  table.insert(out, string.format("## %s:%s (%s) — %s", c.path, range(c), c.side, c.status))
  local lang = c.path:match("%.([%w_]+)$") or ""
  local fence = fence_for(c.snippet or "")
  table.insert(out, fence .. lang)
  vim.list_extend(out, vim.split(c.snippet or "", "\n", { plain = true }))
  table.insert(out, fence)
  for _, m in ipairs(c.thread or {}) do
    local who = m.author .. (m.draft and " (draft)" or "")
    local body = vim.split(m.body or "", "\n", { plain = true })
    body[1] = string.format("**%s:** %s", who, body[1])
    vim.list_extend(out, body)
  end
  return out
end

---@param review review.Review
---@param opts? { show_resolved: boolean }
---@return string[]
function M.render(review, opts)
  opts = opts or {}
  local out = { string.format("# Review %s #%d", review.branch, review.number), "" }
  for _, c in ipairs(model.visible(review, opts.show_resolved)) do
    vim.list_extend(out, M.render_comment(c))
    table.insert(out, "")
  end
  return out
end

function M.run(review)
  local lines = M.render(review, { show_resolved = config.options.show_resolved })
  local target = config.options.export_target
  if target == "clipboard" or target == "both" then
    vim.fn.setreg("+", table.concat(lines, "\n"))
  end
  if target == "buffer" or target == "both" then
    vim.cmd("botright new")
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "markdown"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  vim.notify(string.format("review: exported %d comments (%s)",
    #model.visible(review, config.options.show_resolved), target))
end

return M
