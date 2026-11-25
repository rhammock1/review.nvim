local M = {}

M.defaults = {
  dir = ".review",
  ignore_review_dir = true,
  post_on_submit = false,
  export_target = "both", -- "buffer" | "clipboard" | "both"
  show_resolved = false,
  peek = false, -- preview a comment when the cursor rests on it
  keymaps = {
    comment = "<leader>rc",
    thread = "<leader>rv",
    list = "<leader>rl",
    submit = "<leader>rs",
    export = "<leader>re",
    help = "<leader>r?",
  },
  float_keymaps = {
    save_insert = { "<C-s>" },
    save_normal = { "<CR>" },
    post = { "<C-p>" },
    cancel = { "q", "<Esc>" },
    scroll_up = { "<C-b>" },
    scroll_down = { "<C-f>" },
  },
  signs = { PENDING = "◌", POSTED = "●", RESPONDED = "◆", RESOLVED = "✓" },
}

M.options = vim.deepcopy(M.defaults)

-- Copy list values from `src` over `dst` so lists replace instead of merging by index.
local function replace_lists(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" then
      if vim.islist(v) then
        dst[k] = vim.deepcopy(v)
      elseif type(dst[k]) == "table" then
        replace_lists(dst[k], v)
      end
    end
  end
end

--- Tidy user values so the rest of the plugin sees one shape: key lists are
--- always lists, and false (or "") turns a key, a sign or a whole group off.
local function normalize(o)
  local function group(v) return type(v) == "table" and v or nil end

  local km, fk, sg = group(o.keymaps), group(o.float_keymaps), group(o.signs)
  o.keymaps, o.float_keymaps, o.signs = {}, {}, {}
  for name in pairs(M.defaults.keymaps) do
    local v = km and km[name]
    o.keymaps[name] = v ~= "" and v or false
  end
  for name in pairs(M.defaults.float_keymaps) do
    local v = fk and fk[name]
    if type(v) == "string" and v ~= "" then v = { v } end
    o.float_keymaps[name] = type(v) == "table" and v or {}
  end
  for status, default in pairs(M.defaults.signs) do
    local v = sg and sg[status]
    if sg and v == nil then v = default end
    o.signs[status] = v or ""
  end
end

function M.setup(opts)
  opts = opts or {}
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  replace_lists(M.options, opts)
  normalize(M.options)
  return M.options
end

return M
