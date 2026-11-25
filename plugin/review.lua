-- Defined here rather than in setup() so plugin managers can run it as a build step.
vim.api.nvim_create_user_command("ReviewInstall", function(o)
  require("review.install").run(o.args)
end, {
  nargs = "?",
  complete = function(lead)
    return vim.tbl_filter(function(a) return vim.startswith(a, lead) end, require("review.install").names())
  end,
  desc = "Review: install the agent side (skill and watcher)",
})
