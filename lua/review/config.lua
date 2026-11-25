local M = {}

M.defaults = {
  dir = ".review",
  ignore_review_dir = true,
  post_on_submit = false,
  export_target = "both", -- "buffer" | "clipboard" | "both"
  show_resolved = false,
  keymaps = {
    comment = "<leader>rc",
    thread = "<leader>rv",
    list = "<leader>rl",
    submit = "<leader>rs",
    export = "<leader>re",
  },
  float_keymaps = {
    save_insert = { "<C-s>" },
    save_normal = { "<CR>" },
    post = { "<C-p>" },
    cancel = { "q", "<Esc>" },
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

function M.setup(opts)
  opts = opts or {}
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  replace_lists(M.options, opts)
  return M.options
end

return M
