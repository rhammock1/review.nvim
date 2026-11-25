local config = require("review.config")

local M = {}

--- Key list as text, with an optional mode suffix; nil when the key is off.
local function keys(list, mode)
  if #list == 0 then return nil end
  return table.concat(list, " ") .. (mode and (" (" .. mode .. ")") or "")
end

--- Join the non-nil parts, or nil when there are none.
local function join(...)
  local parts = {}
  for i = 1, select("#", ...) do
    local p = select(i, ...)
    if p then table.insert(parts, p) end
  end
  return #parts > 0 and table.concat(parts, "  ") or nil
end

--- Cheat-sheet lines built from the current config, so remaps show up.
---@return string[]
function M.lines()
  local km, fk, sg = config.options.keymaps, config.options.float_keymaps, config.options.signs
  local rows = {}
  local function section(title)
    if #rows > 0 then table.insert(rows, false) end
    table.insert(rows, title)
  end
  local function row(key, what) table.insert(rows, { key, what }) end
  local function global(name, cmd, what)
    row(km[name] and (km[name] .. "  " .. cmd) or cmd, what)
  end

  section("Anywhere")
  global("comment", ":ReviewComment", "New comment on a line or selection; on a comment: open thread")
  global("thread", ":ReviewThread", "Show the thread under the cursor")
  global("list", ":ReviewList[!]", "List comments in Telescope (! = incl. resolved)")
  global("submit", ":ReviewSubmit", "Post all pending comments/replies to the agent")
  global("export", ":ReviewExport", "Export review as Markdown")
  row(":ReviewResolve", "Resolve the comment under the cursor")
  row(":ReviewNew", "Start a fresh review (#n+1) for this branch")
  global("help", ":ReviewHelp", "This cheat-sheet")

  local popup = {
    { join(keys(fk.save_normal, "normal"), keys(fk.save_insert, "insert")),
      config.options.post_on_submit and "Post and stay open" or "Save as pending draft" },
    { keys(fk.post), "Post now (agent picks it up) and stay open" },
    { keys(fk.cancel, "normal"), "Close (asks before discarding text)" },
    { join(keys(fk.scroll_up), keys(fk.scroll_down)), "Scroll the thread" },
  }
  popup = vim.tbl_filter(function(r) return r[1] ~= nil end, popup)
  if #popup > 0 then
    section("In the comment popup")
    for _, r in ipairs(popup) do row(r[1], r[2]) end
  end

  section("In the list (Telescope)")
  row("<CR>", "Jump to comment")
  row("<C-r>  <C-e>", "Reply  /  edit (pending or draft only)")
  row("<M-r>  <M-d>", "Resolve or reopen  /  delete")
  row("<M-h>", "Show/hide resolved")

  section("Signs")
  local function sign(status) return sg[status] ~= "" and (sg[status] .. " " .. status:lower()) or nil end
  local signs = join(sign("PENDING"), sign("POSTED"), sign("RESPONDED"), sign("RESOLVED"))
  if signs then row(signs, "") end
  row("· moved?", "Snippet changed; shown at stored line")

  local width = 0
  for _, r in ipairs(rows) do
    if type(r) == "table" and r[2] ~= "" then width = math.max(width, vim.fn.strdisplaywidth(r[1])) end
  end
  local out = {}
  for _, r in ipairs(rows) do
    if r == false then
      table.insert(out, "")
    elseif type(r) == "string" then
      table.insert(out, r)
    elseif r[2] == "" then
      table.insert(out, "  " .. r[1])
    else
      table.insert(out, "  " .. r[1] .. string.rep(" ", width - vim.fn.strdisplaywidth(r[1]) + 2) .. r[2])
    end
  end
  return out
end

--- Open the cheat-sheet in a centered float. q / <Esc> closes it.
---@return integer winid
function M.open()
  local cur = vim.api.nvim_get_current_win()
  if vim.w[cur].review_help then return cur end
  -- From insert mode (<C-o> or an insert mapping): leave it, and return on close.
  local from_insert = vim.fn.mode(1):match("^n?i") ~= nil
  if from_insert then vim.cmd("stopinsert") end
  local lines = M.lines()
  local width = 0
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l)) end
  width = math.max(math.min(width + 2, vim.o.columns - 4), 1)
  local height = math.max(math.min(#lines, vim.o.lines - 4), 1)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor", style = "minimal", border = "rounded",
    width = width, height = height,
    row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    title = " review.nvim ", title_pos = "center",
    footer = " q close ", footer_pos = "right",
  })
  -- Mark the window before entering it, so the comment popup stays open underneath.
  vim.w[win].review_help = true
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.api.nvim_set_current_win(win)
  -- Highlight section titles.
  for i, l in ipairs(lines) do
    if l ~= "" and not l:match("^  ") then
      vim.api.nvim_buf_add_highlight(buf, -1, "Title", i - 1, 0, -1)
    end
  end
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, function()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
      if from_insert and vim.api.nvim_get_current_win() == cur then
        -- Typing usually continues at the end of the line.
        vim.cmd(vim.fn.col(".") >= vim.fn.col("$") - 1 and "startinsert!" or "startinsert")
      end
    end, { buffer = buf, nowait = true })
  end
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf, once = true,
    callback = function()
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
      end)
    end,
  })
  return win
end

return M
