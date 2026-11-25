-- Merges the review file on disk with Neovim's in-memory copy.
-- Neither input is mutated. Ownership rules:
--   * comments and messages are unioned by id; tombstones (deleted) stick
--   * location fields and user messages come from `mine`
--   * agent messages come from `disk`
--   * status/updated_at come from whichever side was updated later (tie: mine)
local M = {}

local function merge_thread(disk_thread, mine_thread)
  local by_id, order = {}, {}
  local function add(m, prefer)
    local existing = by_id[m.id]
    if not existing then
      by_id[m.id] = vim.deepcopy(m)
      table.insert(order, m.id)
    elseif prefer then
      by_id[m.id] = vim.deepcopy(m)
    end
  end
  for _, m in ipairs(mine_thread or {}) do add(m, false) end
  for _, m in ipairs(disk_thread or {}) do add(m, m.author == "agent") end

  local items = {}
  for i, id in ipairs(order) do items[i] = { msg = by_id[id], idx = i } end
  table.sort(items, function(a, b)
    if a.msg.at ~= b.msg.at then return (a.msg.at or "") < (b.msg.at or "") end
    return a.idx < b.idx
  end)
  return vim.tbl_map(function(it) return it.msg end, items)
end

local function merge_comment(d, m)
  local out = vim.deepcopy(m)
  out.thread = merge_thread(d.thread, m.thread)
  if d.deleted or m.deleted then out.deleted = true end
  local du, mu = d.updated_at or "", m.updated_at or ""
  if du > mu then
    out.status = d.status
    out.updated_at = d.updated_at
  elseif du == mu and d.status == "RESPONDED" and m.status ~= "RESOLVED" then
    -- Timestamps have 1s resolution, so ties are common. The agent's answer
    -- wins a tie unless the user has posted something after it.
    local last
    for i = #out.thread, 1, -1 do
      if not out.thread[i].draft then last = out.thread[i] break end
    end
    if last and last.author == "agent" then out.status = "RESPONDED" end
  end
  return out
end

---@param disk review.Review|nil
---@param mine review.Review
---@return review.Review
function M.merge(disk, mine)
  local out = vim.deepcopy(mine)
  if not disk then return out end

  local disk_by_id = {}
  for _, c in ipairs(disk.comments or {}) do disk_by_id[c.id] = c end

  local seen = {}
  out.comments = {}
  for _, c in ipairs(mine.comments or {}) do
    seen[c.id] = true
    local d = disk_by_id[c.id]
    table.insert(out.comments, d and merge_comment(d, c) or vim.deepcopy(c))
  end
  for _, d in ipairs(disk.comments or {}) do
    if not seen[d.id] then table.insert(out.comments, vim.deepcopy(d)) end
  end
  return out
end

return M
