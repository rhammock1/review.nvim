local M = {}

local function clamp(c, nlines, moved)
  local n = math.max(nlines, 1)
  local start = math.min(math.max(c.line_start, 1), n)
  local finish = math.min(math.max(c.line_end or c.line_start, start), n)
  return { start = start, finish = finish, moved = moved }
end

--- Find where a comment's snippet now lives in `lines`.
---@param lines string[]
---@param c { line_start: integer, line_end: integer, snippet: string }
---@return { start: integer, finish: integer, moved: boolean }
function M.locate(lines, c)
  if not c.snippet or c.snippet == "" then
    return clamp(c, #lines, false)
  end
  local snip = vim.split(c.snippet, "\n", { plain = true })
  local k = #snip
  local best, best_dist
  for i = 1, #lines - k + 1 do
    local match = true
    for j = 1, k do
      if lines[i + j - 1] ~= snip[j] then
        match = false
        break
      end
    end
    if match then
      local dist = math.abs(i - c.line_start)
      if not best or dist < best_dist then
        best, best_dist = i, dist
      end
    end
  end
  if best then
    return { start = best, finish = best + k - 1, moved = false }
  end
  return clamp(c, #lines, true)
end

return M
