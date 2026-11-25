---@class review.Location
---@field path string
---@field side "new"|"old"
---@field commit string
---@field worktree boolean
---@field line_start integer
---@field line_end integer
---@field snippet string

---@class review.Message
---@field id string
---@field author "user"|"agent"
---@field body string
---@field at string
---@field draft? true

---@class review.Comment: review.Location
---@field id string
---@field status "PENDING"|"POSTED"|"RESPONDED"|"RESOLVED"
---@field created_at string
---@field updated_at string
---@field thread review.Message[]
---@field deleted? true

---@class review.Review
---@field version integer
---@field branch string
---@field base? string
---@field number integer
---@field created_at string
---@field comments review.Comment[]

local M = {}

local seeded = false

function M.new_id(prefix)
  if not seeded then
    math.randomseed(vim.uv.hrtime() % 2 ^ 31 + vim.uv.os_getpid())
    seeded = true
  end
  return string.format("%s_%06x", prefix, math.random(0, 0xFFFFFF))
end

function M.now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function touch(c)
  c.updated_at = M.now()
end

function M.new_review(branch, base, number)
  return { version = 1, branch = branch, base = base, number = number,
           created_at = M.now(), comments = {} }
end

local function new_message(author, body, draft)
  return { id = M.new_id("m"), author = author, body = body, at = M.now(),
           draft = draft or nil }
end

function M.new_comment(loc, body, post)
  local now = M.now()
  return {
    id = M.new_id("c"),
    status = post and "POSTED" or "PENDING",
    path = loc.path, side = loc.side, commit = loc.commit, worktree = loc.worktree,
    line_start = loc.line_start, line_end = loc.line_end, snippet = loc.snippet,
    created_at = now, updated_at = now,
    thread = { new_message("user", body) },
  }
end

--- Add a user reply. A posted reply reactivates the thread (POSTED) unless the
--- comment itself is still a PENDING draft.
function M.reply(c, body, post)
  local m = new_message("user", body, not post)
  table.insert(c.thread, m)
  if post and c.status ~= "PENDING" then
    c.status = "POSTED"
  end
  touch(c)
  return m
end

--- Post a PENDING comment and/or any draft replies. Returns whether anything changed.
function M.post(c)
  local changed = false
  for _, m in ipairs(c.thread) do
    if m.draft then
      m.draft = nil
      changed = true
    end
  end
  if c.status == "PENDING" or (changed and c.status ~= "POSTED") then
    c.status = "POSTED"
    changed = true
  end
  if changed then touch(c) end
  return changed
end

function M.resolve(c)
  c.status = "RESOLVED"
  touch(c)
end

function M.reopen(c)
  if c.status == "RESOLVED" then
    c.status = "POSTED"
    touch(c)
  end
end

function M.delete(c)
  c.deleted = true
  touch(c)
end

function M.edit_message(c, msg_id, body)
  for _, m in ipairs(c.thread) do
    if m.id == msg_id then
      if m.author ~= "user" then return false, "agent" end
      if c.status ~= "PENDING" and not m.draft then return false, "posted" end
      m.body = body
      touch(c)
      return true
    end
  end
  return false, "not found"
end

function M.find(review, id)
  for _, c in ipairs(review.comments) do
    if c.id == id then return c end
  end
end

function M.visible(review, show_resolved)
  local out = {}
  for _, c in ipairs(review.comments) do
    if not c.deleted and (show_resolved or c.status ~= "RESOLVED") then
      table.insert(out, c)
    end
  end
  return out
end

function M.has_agent_reply_after(c, iso)
  for _, m in ipairs(c.thread) do
    if m.author == "agent" and m.at > iso then return true end
  end
  return false
end

return M
