# review.nvim — inline review comments for an agent

Date: 2026-11-25 · Status: draft for approval

## Intent

Robert reviews his own PR diffs in Neovim (diffview, `<leader>gd` →
`DiffviewOpen origin/dev...HEAD`). Today he copies lines into an agent
session and asks questions or notes needed changes. This plugin replaces
that copy/paste: he leaves inline comments on lines or selections while
reviewing, they land in a review file that a coding agent (Claude Code)
watches, and the agent's answers come back into Neovim as a thread on the
same comment. Goal: stay in Neovim, feel near real-time.

Personal plugin for now; keep posting to GitHub possible later.

## Goals

- `<leader>rc` on a line / visual selection opens a small float just below
  the selection: header `path/to/file.js  L42–48 (new)`, editable body.
- Each comment captures path, diff side, line range, commit, and the selected
  code snippet, so the agent can locate it even after lines drift.
- Comments are threads: Robert and the agent alternate messages.
- Status lifecycle `PENDING → POSTED → RESPONDED → RESOLVED`; the agent only
  acts on `POSTED`.
- Agent responses appear in Neovim automatically (file watch), without leaving
  the diff.
- List, jump to, reply, edit, delete, resolve, reopen comments from a
  Telescope picker.
- Export the review as Markdown to a buffer and/or clipboard.
- Keymaps and behavior configurable through `setup()`.
- A Claude Code skill + watcher script so the agent knows the file format and
  reacts to newly posted comments.

## Non-goals

- Posting to GitHub (format keeps path/side/line/commit so a later
  `:ReviewExportGithub` via `gh api` is possible — not built now).
- Comment types/labels (question vs change, nit, blocking). The agent infers
  intent from wording.
- Multi-user review; a review file belongs to one person and one agent.
- Storing comments only in a buffer. The file is the single source of truth;
  buffers are views/exports.

## Anti-goals (failure even if it "works")

- Losing a comment or an agent reply because both sides wrote the file at once.
- The agent starting work on a draft (`PENDING`) comment.
- Comment UI that breaks diffview's side-by-side alignment.
- Keymaps that shadow existing mappings in Robert's config.

## Constraints

- Neovim 0.12.6, lazy.nvim, leader = Space, Ghostty terminal (kitty keyboard
  protocol available).
- Diffview buffers are `diffview://…` URIs, not real files. File path, side,
  and revision must come from diffview: `require('diffview.lib').get_current_view()`,
  the current window's layout window's `file` (`file.path`, `file.rev`,
  `file.symbol` — `"a"` = left/old, `"b"` = right/new).
- Telescope + plenary are installed; `jq` is at `/usr/bin/jq`; `fswatch` is
  not installed (don't depend on it).
- Existing `<leader>r*` mapping: `<leader>rp` (copy relative path). Existing
  `<leader>s*`: Telescope searches. Don't reuse these.
- No global git excludesfile is configured.

## Approaches considered

1. **Shared JSON file, watched by both sides — CHOSEN.** Neovim watches with
   libuv; the agent runs a small watcher script in the background that exits
   when a `POSTED` comment appears. Simple, inspectable, survives restarts,
   agent-agnostic.
2. Agent drives Neovim over its RPC socket (`nvim --listen`). Instant, no
   merging, but only works while Neovim is up on a known socket and couples
   the agent to the editor session.
3. Extend octo.nvim. Has inline threads, but is GitHub-API-centric; bending it
   to local files + an agent is more work than ~600 lines of our own Lua.

## Design

### Packaging

Local plugin at `~/.config/nvim/plugins/review.nvim/` (`lua/review/*.lua`,
`plugin/`, `docs/`, `tests/`), loaded via a lazy.nvim spec with
`dir = vim.fn.stdpath("config") .. "/plugins/review.nvim"`. Separate dir so it
can become its own git repo later.

### Review file

- Location: `<repo toplevel>/.review/`. Repo toplevel comes from the diffview
  view's adapter when in diffview, else `git rev-parse --show-toplevel`.
- Name: `YYYY-MM-DD-<branch>-<n>.json`, date = creation date, branch with `/`
  replaced by `-`, `n` per branch starting at 1.
- **Active review** for a branch = the highest `n` for that branch (any date).
  Created lazily on the first comment. `:ReviewNew` creates `n+1`.
- On first creation of `.review/`, append `.review/` to `.git/info/exclude`
  if not already ignored (local-only; no global gitignore change). Config:
  `ignore_review_dir = true`.

Schema (version 1):

```json
{
  "version": 1,
  "branch": "feat/order-sync",
  "base": "origin/dev",
  "number": 1,
  "created_at": "2026-11-25T14:03:11Z",
  "comments": [
    {
      "id": "c_7f3a9b",
      "status": "POSTED",
      "path": "src/orders/sync.js",
      "side": "new",
      "commit": "a1b2c3d",
      "line_start": 42,
      "line_end": 48,
      "snippet": "exact text of lines 42–48 on that side",
      "created_at": "…",
      "updated_at": "…",
      "thread": [
        { "id": "m_01", "author": "user",  "body": "Why is this nullable?", "at": "…" },
        { "id": "m_02", "author": "agent", "body": "Because …", "at": "…" }
      ]
    }
  ]
}
```

- `side`: `"new"` (right/after) or `"old"` (left/before, i.e. deleted code).
  Outside diffview, comments are `side: "new"` against the working tree;
  `commit` = `HEAD` sha and a `"worktree": true` flag.
- `commit`: the revision of the side commented on (diffview `file.rev`
  resolved to a sha).
- `base`: the diffview range's left rev if known, else null.

### Status rules

| Transition | Who | When |
|---|---|---|
| → `PENDING` | user | Comment saved as draft |
| `PENDING` → `POSTED` | user | `<leader>rs` (post all pending) or post-now key |
| `POSTED` → `RESPONDED` | agent | Agent appends an `author: "agent"` message |
| `RESPONDED` → `POSTED` | user | User posts a reply in the thread |
| any → `RESOLVED` | user | Resolve action |
| `RESOLVED` → `POSTED` | user | Reopen action |

A user reply saved as draft sits in the thread marked `"draft": true` and
doesn't change status until posted. Only `PENDING` comments and draft
messages can be edited/deleted freely; deleting a posted comment asks for
confirmation.

### Concurrent writes

- Every write: re-read file from disk, merge, write to a temp file in
  `.review/`, `rename` over the target (atomic).
- Merge by comment `id` and message `id` (union). Field ownership: the agent
  only appends thread messages with `author: "agent"` and sets
  `status: "RESPONDED"`; everything else is the user's. On conflict for
  `status`, the later `updated_at` wins.
- Neovim watches the **`.review/` directory** (`vim.uv.new_fs_event`), not the
  file, because atomic rename replaces the inode. Debounce ~150ms, ignore
  events caused by its own writes (compare mtime/hash).

### Comment window

- `<leader>rc` (normal: current line; visual: selection). If the line already
  has a comment, opens that thread instead (thread view + reply box).
- Float anchored just below the last selected line (`relative = "win"`,
  bordered), width ~ min(80, window width), height grows with content.
  Border title: `path  L42–48 (new)`. Buffer `filetype=markdown`, starts in
  insert mode.
- Keys inside the float (configurable):

| Key | Action |
|---|---|
| `<CR>` (normal), `<C-s>` (insert only) | Save as `PENDING` |
| `<C-p>` (any mode) | Post now (`POSTED`) |
| `q`, `<Esc>` (normal) | Cancel; confirm if text was typed |

- `<C-s>` is insert-mode only because Robert's global normal-mode `<C-s>`
  (markdown strikethrough, `lua/rhammock/strikethrough.lua`) must keep
  working in the markdown float. *(Claude's call.)*
- Config `post_on_submit = false`: when true, the save key posts too.

### Diff target and line drift (decided by Robert)

- Change `<leader>gd` in `lua/lazyplugins.lua` to
  `DiffviewOpen origin/dev...HEAD --imply-local`, so the right side is the
  working tree and the agent's uncommitted edits show live in the diff.
- Comments on the working-tree side store `commit` = HEAD sha and
  `"worktree": true`.
- **Re-anchoring is display-only.** When placing marks (and deciding which
  thread `<leader>rc` opens on a line), Neovim searches the buffer for the
  comment's `snippet` (exact multi-line match; nearest match to the stored
  `line_start` wins if several). If not found, place at the stored line with
  a "moved?" indicator. Stored `line_start`/`line_end` are never rewritten,
  so field ownership and merge rules are unchanged.
- Marks for a `side: "new"` comment appear in any buffer showing that path's
  new/working version (diffview right side or the real file); `side: "old"`
  only in diffview left-side buffers.

### Showing comments in the diff

- Sign column icon per status on `line_start` in both diffview buffers and
  normal buffers for the matching path/side (e.g. `◌` pending, `●` posted,
  `◆` responded, `✓` resolved; hidden when resolved by default).
- End-of-line virtual text: short summary, e.g. `💬 2 · agent replied`.
- **No `virt_lines`** in diffview by default — extra virtual lines on one side
  break side-by-side alignment. Full thread opens in the float via
  `<leader>rc` on the line (or `<leader>rv`). Config `inline_thread = false`
  to experiment later.
- Marks refresh on file-watch events and on diffview `file_open_post`.
- `vim.notify` when an agent reply arrives: `review: agent replied on
  sync.js:42`.

### Picker

`<leader>rl` → Telescope picker over the active review: entries
`STATUS  path:line  first line of first message`, preview pane shows snippet +
thread. Resolved hidden by default (toggle key). Actions: `<CR>` jump (in the
open diffview: select file + move cursor on the right side/line; otherwise
open the real file at the line), reply, edit, delete, resolve/reopen. Picker
action keys are the builder's call but must not shadow Telescope's defaults
(`<C-x>`, `<C-v>`, `<C-t>`, `<C-u>`, `<C-d>`, `<C-n>`, `<C-p>`).

### Global keymaps (defaults, all configurable, `false` disables)

| Key | Command | Action |
|---|---|---|
| `<leader>rc` | `:ReviewComment` | New comment / open thread (n, x) |
| `<leader>rv` | `:ReviewThread` | View thread under cursor |
| `<leader>rl` | `:ReviewList` | Telescope picker |
| `<leader>rs` | `:ReviewSubmit` | Post all `PENDING` |
| `<leader>re` | `:ReviewExport` | Markdown export |
| — | `:ReviewNew` | Start review `n+1` for branch |
| — | `:ReviewResolve` | Resolve comment under cursor |

### Export

`:ReviewExport` renders the active review as Markdown (per comment: status,
`path:L42-48 (new)`, fenced snippet with language from extension, thread) into
a scratch buffer and/or `+` register. Config `export_target = "buffer" |
"clipboard" | "both"` (default `"both"`).

### Agent side

- Skill at `~/.claude/skills/review-comments/SKILL.md` describing: where
  review files live, schema, status rules, field ownership, atomic write
  (write temp + `mv`), that it acts only on `POSTED`, appends one
  `author: "agent"` message per pass, sets `RESPONDED`, never resolves.
  Answers questions directly; for change requests makes the change in the
  working tree and explains what it did (doesn't commit unless told).
  Locate code by `snippet` first, line numbers second.
- Watcher script `~/scripts/bin/review-watch [file]`: defaults to the active
  review for the current branch; polls (~2s, `jq`) and exits printing the ids
  of comments in `POSTED` that it hasn't seen. The skill tells the agent to
  run it in the background (Monitor / background Bash), process on exit, and
  restart it — giving the near real-time loop.

### Config shape

```lua
require("review").setup({
  dir = ".review",
  ignore_review_dir = true,
  post_on_submit = false,
  export_target = "both",
  keymaps = { comment = "<leader>rc", thread = "<leader>rv", list = "<leader>rl",
              submit = "<leader>rs", export = "<leader>re" },
  float_keymaps = { save_insert = { "<C-s>" }, save_normal = { "<CR>" },
                    post = { "<C-p>" }, cancel = { "q", "<Esc>" } },
  signs = { PENDING = "◌", POSTED = "●", RESPONDED = "◆", RESOLVED = "✓" },
  show_resolved = false,
})
```

### Builder-settled details *(Claude's calls)*

- Deletes are tombstones (`"deleted": true`) so the union merge can't
  resurrect them; tombstones are skipped in UI/export.
- If a merge would drop user-owned data written by the agent, Neovim keeps
  its own version of user-owned fields.
- The watcher tracks seen work by `(comment id, last user message id)`, so a
  reply that re-posts a thread is picked up again.
- `.git/info/exclude` path comes from `git rev-parse --git-path info/exclude`
  (works in worktrees).

## Left to the builder

- Module layout inside `lua/review/`.
- Exact float sizing/highlights; picker action keys (within the constraint above).
- ID generation scheme.
- Tests: plenary busted for store/merge/status logic at minimum.
