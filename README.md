# review.nvim

Leave inline review comments while reading a diff in Neovim. They're saved to a JSON file a coding agent watches, and the agent's replies show up next to the code as a thread.

```
you: <leader>rc on a line ──► .review/2026-11-25-feat-x-1.json ◄── agent (review-watch + skill)
     ◆ 💬 2 · agent replied ◄────────── file watcher ◄──────────── reply appended
```

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "rhammock1/review.nvim",
  lazy = false,
  build = ":ReviewInstall claude", -- optional: sets up the agent side
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-telescope/telescope.nvim", -- for :ReviewList
    "sindrets/diffview.nvim",
  },
  opts = {},
}
```

## Workflow

1. `<leader>gd` opens `DiffviewOpen origin/dev...HEAD --imply-local`. The right side is your working tree.
2. On a line or a visual selection, press `<leader>rc` and type your comment.
   - `<CR>` (normal) or `<C-s>` (insert) saves it as a **pending** draft. The agent ignores drafts.
   - `<C-p>` **posts** it right away.
   - `q` / `<Esc>` (normal) cancels. Leaving the popup with text in it keeps it open.
3. `<leader>rs` posts every pending comment, including draft replies.
4. In Claude Code, say "watch my review comments". The `review-comments` skill runs `review-watch` and replies to each posted comment.
5. Replies appear as `◆ 💬 2 · agent replied`. Press `<leader>rc` on that line to open the thread and reply. Your reply sets the comment back to POSTED, and the agent picks it up again.
6. `<leader>rl` lists comments (Telescope). `<leader>re` exports Markdown.

## Statuses and signs

| Sign | Status | Meaning |
|---|---|---|
| `◌` | PENDING | Draft. Only you can see it. |
| `●` | POSTED | Waiting for the agent. |
| `◆` | RESPONDED | The agent replied. |
| `✓` | RESOLVED | Done. Hidden unless `show_resolved`. |

`· moved?` after a comment means its saved snippet is no longer in the buffer, so it's pinned to the stored line. Usually that's because the code was changed to address it.

## Keymaps and commands

| Key | Command | |
|---|---|---|
| `<leader>rc` | `:ReviewComment` (range) | New comment, or open the thread on the current line |
| `<leader>rv` | `:ReviewThread` | Show the thread under the cursor |
| `<leader>rl` | `:ReviewList[!]` | Telescope list (`!` includes resolved) |
| `<leader>rs` | `:ReviewSubmit` | Post all pending |
| `<leader>re` | `:ReviewExport` | Markdown to a buffer and/or clipboard |
| | `:ReviewNew` | Start review `n+1` for this branch |
| | `:ReviewResolve` | Resolve the comment under the cursor |
| `<leader>r?` | `:ReviewHelp` | Keymap cheat-sheet popup |
| | `:ReviewInstall {agent}` | Install the agent side (`claude`) |

Keys in the Telescope picker:

| Key | Action |
|---|---|
| `<CR>` | Jump to the comment |
| `<C-r>` | Reply |
| `<C-e>` | Edit (pending comments and draft replies only) |
| `<M-d>` | Delete |
| `<M-r>` | Resolve or reopen |
| `<M-h>` | Show or hide resolved comments |

## Config

```lua
require("review").setup({
  dir = ".review",            -- relative to the repo toplevel
  ignore_review_dir = true,   -- add .review/ to .git/info/exclude
  post_on_submit = false,     -- true: the save keys post immediately
  export_target = "both",     -- "buffer" | "clipboard" | "both"
  show_resolved = false,
  keymaps = { comment = "<leader>rc", thread = "<leader>rv", list = "<leader>rl",
              submit = "<leader>rs", export = "<leader>re", help = "<leader>r?" },  -- false disables
  float_keymaps = { save_insert = { "<C-s>" }, save_normal = { "<CR>" },
                    post = { "<C-p>" }, cancel = { "q", "<Esc>" } },
  signs = { PENDING = "◌", POSTED = "●", RESPONDED = "◆", RESOLVED = "✓" },
})
```

## Agent side

The agent needs a skill, `skills/review-comments`, which holds:

- `SKILL.md`: the file format, status rules, and the atomic-write recipe for the agent.
- `scripts/review-watch`: blocks until new posted comments appear, then prints their ids (`--once`, `--interval`, `FILE`). Needs `jq`. Tests are in `tests/review_watch_test.sh`.

`:ReviewInstall {agent}` links it into place. It never replaces an existing file or directory, and it's safe to run again. Since it's a link, updating the plugin updates the skill.

| Agent | Installs to |
|---|---|
| `claude` | `~/.claude/skills/review-comments` (or under `$CLAUDE_CONFIG_DIR`) |

To add an agent, add an entry to `agents` in `lua/review/install.lua`.

## Development

```bash
./run_tests.sh                       # plenary busted suite (headless)
./run_tests.sh tests/merge_spec.lua  # one file
bash tests/review_watch_test.sh      # watcher script
```

Design: `docs/2026-11-25-review-comments-design.md`. Plan: `docs/plans/2026-11-25-review-nvim.md`.
