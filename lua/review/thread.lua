-- Turns a comment's messages into display lines. No windows or buffers here.
local M = {}

local links = {
  ReviewYou = "Function", ReviewAgent = "DiagnosticOk", ReviewRef = "Directory",
  ReviewTime = "Comment", ReviewKey = "Special", ReviewBorder = "FloatBorder",
}
for group, link in pairs(links) do
  vim.api.nvim_set_hl(0, group, { link = link, default = true })
end

local names = { user = "You", agent = "Agent" }
local groups = { user = "ReviewYou", agent = "ReviewAgent" }

local function cells(s) return vim.fn.strdisplaywidth(s) end

--- Text to repeat in front of a line's continuations.
local function hang(line)
  local quote = line:match("^%s*>[%s>]*")
  if quote then return quote end
  local marker = line:match("^%s*[-*+]%s+") or line:match("^%s*%d+[.)]%s+") or line:match("^%s*")
  return string.rep(" ", cells(marker))
end

local function wrap_line(line, width, out)
  line = line:match("^(.*%S)") or ""
  local prefix = hang(line)
  local cur, has_word = line:match("^%s*"), false
  for gap, word in line:gmatch("(%s*)(%S+)") do
    if not has_word then
      cur, has_word = cur .. word, true
    elseif cells(cur .. gap .. word) > width and vim.trim(cur) ~= vim.trim(prefix) then
      table.insert(out, cur)
      cur = prefix .. word
    else
      cur = cur .. gap .. word
    end
  end
  table.insert(out, cur)
end

--- Wrap at spaces only, so references like `types.ts:93` stay whole. Fenced
--- code and tables keep their own lines.
---@param text string
---@param width integer
---@return string[]
function M.wrap(text, width)
  local out, fence = {}, nil
  for _, line in ipairs(vim.split((text:gsub("\r", "")), "\n", { plain = true })) do
    local marker = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
    if fence then
      if marker and marker:sub(1, 1) == fence:sub(1, 1) and #marker >= #fence then fence = nil end
      table.insert(out, line)
    elseif marker then
      fence = marker
      table.insert(out, line)
    elseif line:match("^%s*|") then
      table.insert(out, line)
    else
      wrap_line(line, width, out)
    end
  end
  return out
end

--- Seconds since the epoch for a UTC timestamp, without the local time zone.
local function epoch(iso)
  if type(iso) ~= "string" then return nil end
  local y, mo, d, h, mi, s = iso:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)[%d.]*Z$")
  if not y then return nil end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  -- Days from civil date: count from March so leap days fall at year end.
  if mo <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (mo + (mo > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return (era * 146097 + doe - 719468) * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
end

---@param iso any timestamp from the review file
---@param now integer
---@return string "" when it can't tell
function M.ago(iso, now)
  local t = epoch(iso)
  if not t then return "" end
  local age = now - t
  if age < 60 then return "just now" end
  if age < 3600 then return math.floor(age / 60) .. "m ago" end
  if age < 86400 then return math.floor(age / 3600) .. "h ago" end
  if age < 30 * 86400 then return math.floor(age / 86400) .. "d ago" end
  return iso:sub(1, 10)
end

local WORKING_FOR = 15 * 60

--- Is the agent working on this comment? A mark older than this was most
--- likely left by an agent that stopped.
---@param comment review.Comment
---@param now? integer
function M.working(comment, now)
  return M.working_left(comment, now) > 0
end

--- Seconds until the working mark counts as stale; 0 when it isn't shown.
--- A mark more than five minutes in the future (a wrong clock) doesn't count.
function M.working_left(comment, now)
  local t = epoch(comment.working)
  local age = t and (now or os.time()) - t
  if not age or age < -300 then return 0 end
  return math.max(WORKING_FOR - age, 0)
end

---@param m review.Message
function M.name(m)
  return (names[m.author] or "Unknown") .. (m.draft and " (draft)" or ""), groups[m.author] or "ReviewTime"
end

--- Body text of a message as the agent or user wrote it.
function M.body(m)
  return type(m.body) == "string" and m.body or ""
end

---@class review.Ref
---@field first integer byte column where it starts (1-based)
---@field last integer byte column where it ends (inclusive)
---@field path string
---@field line integer
---@field line_end integer

--- `file.ext:line` and `file.ext:line-line` references in a line of text.
---@return review.Ref[]
function M.refs(line)
  local out = {}
  for at, word in line:gmatch("()(%S+)") do
    -- The pattern backtracks badly on very long words, which aren't references.
    local from = #word <= 300 and not word:find("://", 1, true) and 1 or nil
    while from do
      local a, b = word:find("[%w_./@~-]+%.%a%w*:%d+", from)
      if not a then break end
      local range = word:match("^%-%d+", b + 1)
      if range then b = b + #range end
      -- After a backslash it's the end of a Windows path, which would open the wrong file.
      if word:sub(a - 1, a - 1) ~= "\\" then
        local path, l1, l2 = word:sub(a, b):match("^(.-):(%d+)%-?(%d*)$")
        table.insert(out, { first = at + a - 1, last = at + b - 1, path = path,
          line = tonumber(l1), line_end = tonumber(l2) or tonumber(l1) })
      end
      from = b + 1
    end
  end
  return out
end

local function mark_refs(line, row, marks)
  for _, ref in ipairs(M.refs(line)) do
    table.insert(marks, { row = row, col = ref.first - 1,
      opts = { end_col = ref.last, hl_group = "ReviewRef", priority = 200 } })
  end
end

--- Display lines for a thread, with one space of padding on each side.
---@param comment review.Comment
---@param width integer
---@param now? integer
---@return string[] lines, { row: integer, col: integer, opts: table }[] marks
function M.render(comment, width, now)
  now = now or os.time()
  local lines, marks = {}, {}
  for i, m in ipairs(comment.thread or {}) do
    if i > 1 then table.insert(lines, "") end
    local name, group = M.name(m)
    table.insert(lines, " " .. name)
    table.insert(marks, { row = #lines - 1, col = 1,
      opts = { end_col = #name + 1, hl_group = group, priority = 200 } })
    local age = M.ago(m.at, now)
    if age ~= "" then
      table.insert(marks, { row = #lines - 1, col = 0,
        opts = { virt_text = { { age .. " ", "ReviewTime" } }, virt_text_pos = "right_align" } })
    end
    for _, l in ipairs(M.wrap(M.body(m), math.max(width - 2, 1))) do
      table.insert(lines, l == "" and "" or " " .. l)
      mark_refs(lines[#lines], #lines - 1, marks)
    end
  end
  if M.working(comment, now) then
    if #lines > 0 then table.insert(lines, "") end
    table.insert(lines, " Agent is working on it…")
    table.insert(marks, { row = #lines - 1, col = 1, opts = { end_col = #lines[#lines], hl_group = "ReviewTime", priority = 200 } })
  end
  if #lines == 0 then lines = { "" } end
  return lines, marks
end

return M
