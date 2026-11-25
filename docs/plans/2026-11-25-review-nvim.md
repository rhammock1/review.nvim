# review.nvim Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A local Neovim plugin for leaving threaded inline review comments in diffview, stored in a shared JSON file, which a Claude Code agent watches and answers.

**Architecture:** Pure-Lua core (`model`, `merge`, `anchor`, `export`) with no editor side effects and full unit tests. `store`/`git`/`context` add file and diffview I/O. UI layers (`float`, `marks`, `watch`, `picker`) and wiring (`init`) sit on top. The agent side is a bash+jq watcher script plus a Claude Code skill.

**Tech Stack:** Lua on Neovim 0.12.6, `vim.uv`, `vim.json`, diffview.nvim internals, telescope.nvim, plenary.nvim (busted tests), bash + `/usr/bin/jq`.

**Spec:** `~/.config/nvim/plugins/review.nvim/docs/2026-11-25-review-comments-design.md`. Read it before any task.

## Global Constraints

- Plugin root: `~/.config/nvim/plugins/review.nvim/` (abbreviated `$P` below). Modules live under `$P/lua/review/`.
- Neovim 0.12.6. No new third-party dependencies beyond telescope and plenary, which are already installed. Don't use `fswatch`.
- Review files live at `<toplevel>/.review/YYYY-MM-DD-<branch with / → ->-<n>.json`. Schema `version: 1`, exactly as in the spec.
- Statuses: exactly `PENDING`, `POSTED`, `RESPONDED`, `RESOLVED`. Authors: exactly `"user"` and `"agent"`.
- Timestamps: `os.date("!%Y-%m-%dT%H:%M:%SZ")`. Comment ids are `c_` plus 6 hex characters; message ids are `m_` plus 6 hex characters.
- JSON: write with `vim.json.encode(review, { indent = "  " })` and read with `vim.json.decode(s, { luanil = { object = true, array = true } })`. Empty Lua tables encode as `[]`, which is correct for `comments` and `thread`.
- Writes are atomic: write `<file>.tmp-<pid>` in `.review/`, then `vim.uv.fs_rename`.
- Default keymaps: `<leader>rc` (n, x), `<leader>rv`, `<leader>rl`, `<leader>rs`, `<leader>re`. Never `<leader>rp` or `<leader>s*`.
- Float keys: `<CR>` (normal) and `<C-s>` (insert only) save as PENDING. `<C-p>` (n, i) posts. `q` and `<Esc>` (normal) cancel. No `<D-CR>`.
- Don't use `virt_lines` in diffview buffers. Show a sign plus an end-of-line `virt_text` only.
- Run tests with: `cd $P && nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua', sequential = true}"`

## Review Focus

1. **The agent writes while Neovim writes.** No user comment, reply, or agent message is lost, and deleted comments stay deleted. Test: `merge_spec` "interleaved writes keep both sides" (Task 3).
2. **The review file is hand-edited or malformed** (bad JSON, or missing `thread`). Neovim warns and doesn't overwrite the file. Test: `store_spec` "refuses to write over unparseable file" (Task 4).
3. **The snippet appears twice in the file**, or the agent rewrote it. The comment goes to the copy nearest its stored line, or to the stored line marked `moved`. Tests: `anchor_spec` "nearest of duplicates" and "missing snippet falls back" (Task 5).
4. **Neovim's own write fires the watcher.** No refresh loop and no "agent replied" notice for its own write. Test: `watch_spec` "ignores own write" (Task 9).
5. **The branch name has slashes, or HEAD is detached.** The filename stays flat, and a detached HEAD uses `detached-<short sha>`. Test: `store_spec` "branch slug" (Task 4).

---

### Task 1: Scaffold, test harness, config

**Files:**
- Create: `$P/lua/review/config.lua`, `$P/tests/minimal_init.lua`, `$P/tests/config_spec.lua`, `$P/.gitignore` (containing `.review/`)

**Interfaces:**
- Produces: `config.defaults` (table, exactly the spec's "Config shape" with `float_keymaps = { save_insert = {"<C-s>"}, save_normal = {"<CR>"}, post = {"<C-p>"}, cancel = {"q","<Esc>"} }`). `config.setup(opts: table?)` deep-merges into `config.options`, where a list value replaces the default list rather than merging with it. `config.options` holds the current settings.

- [ ] **Step 1:** `cd $P && git init`. Write `tests/minimal_init.lua`: prepend `$P` and `~/.local/share/nvim/lazy/plenary.nvim` to `runtimepath`, then `runtime plugin/plenary.vim`.
- [ ] **Step 2: Write the failing test** `config_spec.lua`:
  - "defaults": `config.setup()` gives `options.keymaps.comment == "<leader>rc"` and `options.post_on_submit == false`.
  - "override list replaces": `setup({ float_keymaps = { post = { "<C-g>" } } })` gives `options.float_keymaps.post` equal to `{ "<C-g>" }`, and `save_normal` is still `{ "<CR>" }`.
  - "false disables": `setup({ keymaps = { export = false } })` gives `options.keymaps.export == false`.
- [ ] **Step 3:** Run the tests. Expected: FAIL, module not found.
- [ ] **Step 4:** Implement `config.lua`. Merge with `vim.tbl_deep_extend("force", ...)`, then copy any list-valued keys from opts over the result.
- [ ] **Step 5:** Run the tests. Expected: PASS.
- [ ] **Step 6:** Commit `feat: scaffold review.nvim with config and test harness`.

### Task 2: Model (comments, messages, status transitions)

**Files:** Create `$P/lua/review/model.lua`, `$P/tests/model_spec.lua`

**Interfaces:**
- Types (in LuaLS annotations):
  - `Location = { path, side: "new"|"old", commit, worktree: boolean, line_start, line_end, snippet }`
  - `Message = { id, author, body, at, draft?: true }`
  - `Comment = Location + { id, status, created_at, updated_at, thread: Message[], deleted?: true }`
  - `Review = { version = 1, branch, base?, number, created_at, comments: Comment[] }`
- Produces:
  - `model.new_id(prefix: "c"|"m") -> string`, `model.now() -> string`
  - `model.new_review(branch: string, base: string?, number: integer) -> Review`
  - `model.new_comment(loc: Location, body: string, post: boolean) -> Comment`. Status is `POSTED` if `post`, else `PENDING`. It has one user message.
  - `model.reply(c, body, post: boolean) -> Message`
  - `model.post(c) -> boolean`: changed or not
  - `model.resolve(c)`, `model.reopen(c)`, `model.delete(c)`
  - `model.edit_message(c, msg_id, body) -> boolean, string?`
  - `model.find(review, id) -> Comment?`
  - `model.visible(review, show_resolved) -> Comment[]`: excludes `deleted`
  - `model.has_agent_reply_after(c, iso: string) -> boolean`
- Every mutation sets `updated_at = model.now()`.

- [ ] **Step 1: Write the failing tests:**
  - "new_comment pending": status is `PENDING`, `#thread == 1`, `thread[1].author == "user"`, id matches `^c_%x%x%x%x%x%x$`.
  - "post pending": `post(c)` returns true and status is `POSTED`. A second `post` returns false.
  - "reply posted on RESPONDED": status `RESPONDED`, then `reply(c, "x", true)` gives `POSTED`, and the new message has no `draft`.
  - "reply draft keeps status": status `RESPONDED`, then `reply(c, "x", false)` leaves status `RESPONDED` and the message has `draft == true`. Then `post(c)` gives `POSTED` and clears `draft` on every message.
  - "reply on PENDING stays PENDING": `reply(c, "x", true)` on a PENDING comment leaves it `PENDING`.
  - "resolve and reopen": status `RESOLVED`, then `reopen` gives `POSTED`. `reopen` on a non-RESOLVED comment is a no-op.
  - "delete is tombstone": after `delete(c)`, `c.deleted == true` and `visible(review, true)` excludes it.
  - "edit rules": editing a message works on a `PENDING` comment and on a draft message. On a posted, non-draft message it returns `false, "posted"`.
  - "visible hides resolved": `visible(r, false)` excludes `RESOLVED`. `visible(r, true)` includes it.
- [ ] **Step 2:** Run the tests. Expected: FAIL.
- [ ] **Step 3:** Implement `model.lua`.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit `feat: comment model and status transitions`.

### Task 3: Merge

**Files:** Create `$P/lua/review/merge.lua`, `$P/tests/merge_spec.lua`

**Interfaces:** Produces `merge.merge(disk: Review?, mine: Review) -> Review`. It's pure and mutates neither input.

Rules, from the spec and its builder-settled details:
- Top-level fields come from `mine`.
- Comments are unioned by `id`. Order follows `mine`, then comments that exist only on disk, in disk order.
- `deleted = disk.deleted or mine.deleted`.
- Location fields come from `mine`.
- Thread messages are unioned by `id`. For a message in both, `author == "user"` takes mine's version and `author == "agent"` takes disk's. Order is stable by `at`, with ties broken by first appearance (mine before disk).
- `status` and `updated_at` come from whichever side has the later `updated_at`. On a tie, `mine` wins.

- [ ] **Step 1: Write the failing tests:**
  - "nil disk returns copy of mine"
  - "agent reply survives": disk has an extra agent message, status `RESPONDED`, and a later `updated_at`. The result contains the message and status is `RESPONDED`.
  - "user reply after agent wins status": mine's `updated_at` is later with status `POSTED`. The result is `POSTED`, and both new messages are present.
  - "tombstone not resurrected": deleted in mine, not deleted on disk. The result is `deleted == true`.
  - "interleaved writes keep both sides": mine adds comment B and a user reply on A. Disk adds an agent reply on A. The result has A with all three messages in `at` order, and B as well.
  - "agent cannot clobber user text": disk changed the `body` of a user message. The result keeps mine's `body`.
- [ ] **Step 2:** Run the tests. Expected: FAIL.
- [ ] **Step 3:** Implement `merge.lua`. Use `vim.deepcopy` at the boundaries.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit `feat: id-based merge for concurrent review writes`.

### Task 4: Git helpers and store

**Files:** Create `$P/lua/review/git.lua`, `$P/lua/review/store.lua`, `$P/tests/store_spec.lua`

**Interfaces:**
- `git.toplevel(cwd: string?) -> string?`
- `git.branch(cwd) -> string`: `git branch --show-current`, or `detached-<short sha>` when that's empty
- `git.sha(rev: string, cwd) -> string?`
- `git.exclude_path(cwd) -> string`: `git rev-parse --git-path info/exclude`, made absolute
- Use `vim.system({...}, { cwd = cwd, text = true }):wait()` for all of them.
- `store.slug(branch) -> string`: replaces `/` with `-`
- `store.dir(toplevel) -> string`
- `store.active_path(toplevel, branch) -> string?`: the highest `n` among files matching `^%d%d%d%d%-%d%d%-%d%d%-<slug>%-(%d+)%.json$`
- `store.new_path(toplevel, branch) -> string, integer`: today's date and `n + 1`
- `store.read(path) -> Review?, string?`: returns nil and no error if the file is missing, and nil plus an error if it's unparseable
- `store.write(path, review) -> boolean, string?`: re-reads the file, runs `merge.merge(disk, review)`, then writes atomically. It refuses if the disk file is unparseable. Returns the merged review as `store.last_written[path] = { review, mtime_ns }`.
- `store.ensure_ignored(toplevel)`: appends `.review/` to the exclude file when `git check-ignore -q .review/` fails and `config.options.ignore_review_dir` is set
- `store.load_active(toplevel, branch, base) -> Review, string`: returns the review and its path. It creates both in memory if none exists, using `n = 1`. Nothing is written until the first comment.

- [ ] **Step 1: Write the failing tests.** In `before_each`, create a temporary git repo with one commit using `vim.fn.tempname()`.
  - "branch slug": `slug("feat/a/b") == "feat-a-b"`. In a detached-HEAD repo, `git.branch` matches `^detached%-%x+$`.
  - "active picks highest n": create files with `-1.json` and `-3.json` under different dates. Then `active_path` ends with `-3.json`.
  - "new_path increments": after the above, `new_path` ends with `<today>-<slug>-4.json`.
  - "write then read roundtrip": a review with no comments reads back with `comments` as an empty table. The raw file contains `"comments": []`.
  - "write merges disk changes": write A, then append an agent message directly to the file with jq-style Lua. Write mine without it. The file still has the agent message.
  - "refuses to write over unparseable file": put `{oops` on disk. `write` returns false with an error, and the file still contains `{oops`.
  - "ensure_ignored idempotent": calling it twice adds exactly one `.review/` line to `.git/info/exclude`.
- [ ] **Step 2:** Run the tests. Expected: FAIL.
- [ ] **Step 3:** Implement `git.lua` and `store.lua`.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit `feat: review file store with atomic merged writes`.

### Task 5: Anchor (re-locating comments by snippet)

**Files:** Create `$P/lua/review/anchor.lua`, `$P/tests/anchor_spec.lua`

**Interfaces:** Produces `anchor.locate(lines: string[], comment: Comment) -> { start: integer, finish: integer, moved: boolean }`. Line numbers are 1-based.

Behavior: split `snippet` on `\n`. Find every index `i` where `lines[i .. i+k-1]` equals the snippet lines exactly. Pick the one with the smallest `|i - line_start|`. Ties go to the earlier one. If there's no match, return the stored range with `moved = true`, clamped to `#lines`.

- [ ] **Step 1: Write the failing tests:**
  - "exact at stored line": `moved == false` and the start equals `line_start`.
  - "shifted down": three lines were inserted above. The start is `line_start + 3` and `moved == false`.
  - "nearest of duplicates": the snippet appears at lines 5 and 40 and `line_start = 37`. The result starts at 40.
  - "missing snippet falls back": the result is the stored range with `moved == true`.
  - "clamps past EOF": `line_start = 999` on a 10-line buffer gives `finish <= 10`.
- [ ] **Step 2:** Run the tests. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit `feat: snippet-based comment re-anchoring`.

### Task 6: Context (where the cursor is)

**Files:** Create `$P/lua/review/context.lua`, `$P/tests/context_spec.lua`

**Interfaces:**
- `context.current(range: {integer, integer}?) -> Ctx?, string?`, where `Ctx = Location + { toplevel, base?, bufnr, winid }`. Without a range it uses the cursor line.
- `context.for_buffer(bufnr) -> { toplevel, path, side }?`: identifies which path and side a buffer shows, for placing marks.

Behavior:
- **In diffview:** `local view = require("diffview.lib").get_current_view()`. Find the layout window whose `.id == nvim_get_current_win()` in `view.cur_layout.windows`. Then:
  - `file.path` gives the path.
  - `file.symbol == "a"` means side `"old"`, otherwise `"new"`.
  - If `file.rev.type == RevType.LOCAL`, it's the worktree: `worktree = true` and `commit = git.sha("HEAD")`. Otherwise `commit = file.rev.commit`.
  - `toplevel = view.adapter.ctx.toplevel`.
  - `base` is the left window's `file.rev.commit`, or nil.
  - For `for_buffer`, search `view.cur_layout.windows` across all views in `require("diffview.lib").views` for `file.bufnr == bufnr`.
- **In a normal file buffer:** the path is relative to `git.toplevel`, `side = "new"`, `worktree = true`, and `commit = HEAD`.
- **Snippet:** the buffer lines in the range, joined with `\n`.
- **Otherwise** (no file, not in a repo, or a diffview panel): return nil plus a message.

- [ ] **Step 1: Write the failing tests** (normal buffers only; diffview gets the manual check in Step 5):
  - "normal buffer line": open a file in a temp repo, put the cursor on line 2, and call `current()`. Expect `path == "a.txt"`, `line_start == 2`, `line_end == 2`, `side == "new"`, `worktree == true`, and the snippet equal to line 2.
  - "visual range": `current({2, 4})` gives a 3-line snippet.
  - "outside repo": a scratch buffer returns nil plus a message.
- [ ] **Step 2:** Run the tests. Expected: FAIL. **Step 3:** Implement. **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5: Manual check.** In `~/path/to/repo` on a feature branch, run `:DiffviewOpen origin/dev...HEAD --imply-local`. On the right side, `:lua =require'review.context'.current()` shows `worktree = true` and a correct path. On the left side it shows `side = "old"` and a 40-character commit.
- [ ] **Step 6:** Commit `feat: resolve comment location from diffview or buffer`.

### Task 7: Markdown export

**Files:** Create `$P/lua/review/export.lua`, `$P/tests/export_spec.lua`

**Interfaces:** Produces:
- `export.render(review, opts?: { show_resolved: boolean }) -> string[]`
- `export.run(review)`: sends the result to `config.options.export_target`. `"buffer"` puts it in a new `nofile` markdown split, `"clipboard"` puts it in `setreg("+")`, and `"both"` does both.

Format per comment:

```
## src/orders/sync.js:L42-48 (new) — POSTED
```js
<snippet>
```
**user:** body
**agent:** body
```

The document opens with `# Review <branch> #<n>`. The fence language is the file extension, with `js`, `ts`, `lua`, `java`, `c`, and `marko` passed through as-is.

- [ ] **Step 1: Write the failing tests:**
  - "header and fence": the output contains `# Review feat/x #1` and the line ```` ```js ````.
  - "thread order": the user message comes before the agent message.
  - "resolved hidden by default", and "deleted never shown".
  - "draft marked": a draft message renders as `**user (draft):**`.
- [ ] **Step 2:** Run the tests. Expected: FAIL. **Step 3:** Implement. **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit `feat: markdown export`.

### Task 8: Comment and thread float

**Files:** Create `$P/lua/review/float.lua`, `$P/tests/float_spec.lua`

**Interfaces:**
- `float.open_new(ctx: Ctx, on_submit: fun(body: string, post: boolean), initial: string?)` (`initial` pre-fills the buffer; used for edit)
- `float.open_thread(ctx: Ctx, comment: Comment, on_submit: fun(body: string, post: boolean))`
- `float.close()`
- `float.state -> { input_buf, input_win, thread_win? }?`, exposed for tests

Behavior:
- **Input float.** It's anchored with `relative = "win"`, `win = ctx.winid`, and `bufpos = { line_end - 1, 0 }`, which puts it below the selection. It has a `rounded` border, and its title is `" <path>  L<s>-<e> (<side>) "`, or `L<s>` when it's a single line.
- **Size.** Width is `math.min(80, winwidth - 4)`. Height starts at 3 and grows with the content up to 15, via `TextChanged` and `TextChangedI`.
- **Buffer.** The buffer is `bufhidden=wipe` with `filetype=markdown`, and it opens in insert mode (`startinsert`).
- **Thread view.** `open_thread` adds a second float, which is read-only (`modifiable=false`), placed directly above the input float in the same column. It shows each message as `user ▸ body` or `agent ▸ body`, with ` (draft)` on drafts. Its title shows the comment status.
- **Keys.** These come from `config.options.float_keymaps` and are buffer-local to the input buffer:
  - `save_insert` (mode `i`) and `save_normal` (mode `n`) call `on_submit(body, config.options.post_on_submit)`.
  - `post` (modes `n` and `i`) calls `on_submit(body, true)`.
  - `cancel` (mode `n`) closes the float. If the buffer isn't empty, it first runs `vim.fn.confirm("Discard comment?", "&Yes\n&No", 2)`.
  - An empty body does nothing on save or post, apart from a notify.
- Leaving the input window (`WinLeave`) closes both floats, but only if they aren't already closing.

- [ ] **Step 1: Write the failing tests** (headless; drive the keys with `vim.api.nvim_feedkeys(..., "x", false)` after replacing the termcodes):
  - "opens below selection": after `open_new`, the input window config is `relative == "win"`, and its title contains `a.txt  L2-4 (new)`.
  - "save pending": set the buffer lines to `{"hello"}`, `stopinsert`, then feed `<CR>`. `on_submit` is called with `"hello", false`, and the float closes.
  - "post": feed `<C-p>`. `on_submit` is called with `"hello", true`.
  - "empty body ignored": feed `<CR>` with an empty buffer. `on_submit` isn't called.
  - "thread shown": after `open_thread`, `thread_win` is valid and its buffer contains `agent ▸`.
- [ ] **Step 2:** Run the tests. Expected: FAIL. **Step 3:** Implement. **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit `feat: comment and thread floats`.

### Task 9: Marks and file watcher

**Files:** Create `$P/lua/review/marks.lua`, `$P/lua/review/watch.lua`, `$P/tests/watch_spec.lua`, `$P/tests/marks_spec.lua`

**Interfaces:**
- `marks.refresh(bufnr, review)`: clears and re-places marks in namespace `review_marks`. For each visible comment whose `path` and side match `context.for_buffer(bufnr)`, it calls `anchor.locate(lines, c)` and places:
  - a sign (`sign_text = config.options.signs[status]`, `sign_hl_group = "Review" .. status`, linking by default to `DiagnosticHint`, `DiagnosticInfo`, `DiagnosticOk`, and `Comment`)
  - end-of-line `virt_text`: `{ "💬 " .. #thread .. (last author is agent and status RESPONDED and " · agent replied" or "") .. (moved and " · moved?" or ""), "Comment" }`
- `marks.refresh_all(review)`: refreshes every loaded buffer that `context.for_buffer` recognizes.
- `marks.comment_at(bufnr, lnum, review) -> Comment?`: finds the comment whose located range contains `lnum`.
- `watch.start(path: string, on_change: fun(review: Review))` and `watch.stop()`. It watches `dirname(path)` with `vim.uv.new_fs_event` and debounces by 150 ms with a `vim.uv` timer. On an event for `basename(path)`, it reads the file and calls `on_change` from `vim.schedule`, unless the file's mtime equals `store.last_written[path].mtime_ns`.
- `watch.on_agent_reply`: inside the `on_change` wrapper in `init` (Task 11), compare the old and new reviews. For each comment that gained an agent message, call `vim.notify("review: agent replied on " .. basename .. ":" .. line_start)`.

- [ ] **Step 1: Write the failing tests:**
  - `marks_spec` "places sign at located line": for a buffer with the snippet shifted by 2, the extmark row is `line_start + 1` (0-based `line_start - 1 + 2`) and its `sign_text` matches `●`.
  - `marks_spec` "resolved hidden": a RESOLVED comment places no extmark when `show_resolved = false`.
  - `marks_spec` "comment_at": returns the comment for a line inside its range and nil outside it.
  - `watch_spec` "fires on external write": start watching. Write the file with `io.open` (not through the store). Wait up to 1000 ms with `vim.wait` for `on_change`.
  - `watch_spec` "ignores own write": `store.write` the file. Within 500 ms, `on_change` is never called.
- [ ] **Step 2:** Run the tests. Expected: FAIL. **Step 3:** Implement. **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit `feat: status signs, re-anchored marks, file watcher`.

### Task 10: Telescope picker

**Files:** Create `$P/lua/review/picker.lua`

**Interfaces:**
- Consumes: `model.visible`, `export.render` (the preview uses render applied to a single-comment review), and `actions` from Task 11.
- Produces: `picker.open(review, actions: { jump, reply, edit, delete, toggle_resolved }, opts: { show_resolved })`

Behavior:
- **Entries.** Each entry displays `string.format("%-9s %s:%d  %s", status, path, line_start, first line of thread[1].body)`. The ordinal is the same string.
- **Preview.** A `previewers.new_buffer_previewer` with markdown highlighting.
- **Keys.** Mapped in `i` and `n` mode:
  - `<CR>` runs jump
  - `<C-r>` runs reply
  - `<C-e>` runs edit
  - `<M-d>` runs delete, after `vim.fn.confirm` if the comment isn't PENDING
  - `<M-r>` runs resolve or reopen
  - `<M-h>` toggles showing resolved comments, by re-opening the picker with the flag flipped
- None of these shadow Telescope's `<C-x>`, `<C-v>`, `<C-t>`, `<C-u>`, `<C-d>`, `<C-n>`, or `<C-p>`.

- [ ] **Step 1:** Implement.
- [ ] **Step 2: Manual check.** With a review file holding three comments, one of them RESOLVED, `:ReviewList` shows two. `<M-h>` shows three. The preview shows the snippet and the thread.
- [ ] **Step 3:** Commit `feat: telescope picker for review comments`.

### Task 11: Wiring (setup, commands, keymaps, config integration)

**Files:**
- Create: `$P/lua/review/init.lua`, `$P/tests/init_spec.lua`
- Modify: `~/.config/nvim/lua/lazyplugins.lua`. Add the spec, and change `<leader>gd` to `<cmd>DiffviewOpen origin/dev...HEAD --imply-local<cr>`.

**Interfaces:**
- Produces:
  - `require("review").setup(opts)`
  - `review.comment(range?)`
  - `review.thread()`
  - `review.list()`
  - `review.submit()`
  - `review.export()`
  - `review.new()`
  - `review.resolve()`
- Session state is `{ toplevel, branch, path, review }`, loaded lazily per toplevel from `context.current()`.

Behavior:
- **`comment(range)`.** If `marks.comment_at` finds a comment on the line, call `float.open_thread`, whose `on_submit` uses `model.reply`. Otherwise call `float.open_new`, whose `on_submit` uses `model.new_comment`. Then:
  1. `store.ensure_ignored`
  2. `store.write`, and set the session review to the merged result
  3. `marks.refresh_all`
  4. `watch.start(path)`, if it isn't running yet
- **`list`** opens the picker with these actions:
  - **jump.** If a diffview view is open on the toplevel, find the file entry with `path` in `view.panel:ordered_file_list()`, then call `view:set_file(entry)`. In a `vim.schedule`, focus `cur_layout.b` (new side) or `cur_layout.a` (old side), and set the cursor to the line from `anchor.locate`. Otherwise run `:edit <toplevel>/<path>` and go to the located line.
  - **reply.** Jump, then open the thread.
  - **edit.** Take the last user message whose `model.edit_message` is allowed, and open `float.open_new` pre-filled with it. If none is editable, notify `posted messages can't be edited`.
  - **delete.** `model.delete`.
  - **toggle_resolved.** `model.resolve` or `model.reopen`.

  Every action writes and refreshes the marks.
- **`submit`.** Run `model.post` on every visible comment, write, and notify `review: posted N comments`.
- **`new`.** Use `store.new_path`, then switch the session to the new path.
- **`resolve`.** Resolve the comment under the cursor.
- **`thread`.** Open the thread for the comment under the cursor, or notify `no comment here`.
- **User commands:** `ReviewComment` (`range = true`), `ReviewThread`, `ReviewList`, `ReviewSubmit`, `ReviewExport`, `ReviewNew`, `ReviewResolve`.
- **Keymaps** come from `config.options.keymaps` and are skipped when `false`:
  - `comment` maps in mode `n`.
  - In mode `x`, map `:<C-u>ReviewComment<CR>` via `'<,'>`. Read the range in the command from `opts.line1` and `opts.line2`.
- **Mark refresh** happens on `BufWinEnter` and on `User DiffviewDiffBufWinEnter`. Check that this event exists in the installed diffview with `rg DiffviewDiffBufWinEnter ~/.local/share/nvim/lazy/diffview.nvim`. If it doesn't, use diffview's `hooks.diff_buf_win_enter` from the lazy spec instead.
- **lazy spec:**

```lua
{
  dir = vim.fn.stdpath("config") .. "/plugins/review.nvim",
  name = "review.nvim",
  dependencies = { "nvim-telescope/telescope.nvim", "sindrets/diffview.nvim" },
  event = "VeryLazy",
  opts = {},
},
```

- [ ] **Step 1: Write the failing test** `init_spec` "comment roundtrip" in a temp repo:
  1. Open `a.txt` and run `setup()`.
  2. Call `review.comment()` and feed `hi<Esc><CR>`.
  3. The file `.review/*-1.json` exists with one `PENDING` comment, `.git/info/exclude` contains `.review/`, and the buffer has one extmark in `review_marks`.
  4. Then call `review.submit()`. The comment is `POSTED`.
- [ ] **Step 2:** Run the tests. Expected: FAIL. **Step 3:** Implement `init.lua`. **Step 4:** Run the full suite. Expected: all PASS.
- [ ] **Step 5:** Edit `lazyplugins.lua` as above. Run `nvim --headless "+Lazy! sync" +qa`, then `nvim --headless -c 'lua require("review")' -c q`. Expected: no errors.
- [ ] **Step 6: Manual end-to-end** in `~/path/to/repo`:
  1. Press `<leader>gd`, and confirm the right side shows uncommitted edits.
  2. Visual-select 3 lines and press `<leader>rc`. The float appears below the selection with the right title. Save with `<CR>`, and the sign `◌` appears.
  3. Press `<leader>rs`, and the sign changes to `●`.
  4. Append an agent message to the JSON with `jq` in another terminal. Within about a second the sign shows `◆`, the virt text says `agent replied`, and a notification fires.
  5. Press `<leader>rc` on that line, and the thread opens.
- [ ] **Step 7:** Commit `feat: wire commands, keymaps, and watcher`. The `lazyplugins.lua` change is outside the plugin repo; there's no git repo there.

### Task 12: Agent side (watcher script and skill)

**Files:**
- Create: `~/scripts/bin/review-watch` (executable), `~/.claude/skills/review-comments/SKILL.md`, `$P/tests/review_watch_test.sh`

**Interfaces:**
- `review-watch [FILE] [--once] [--interval SECS]`. With no FILE, it resolves the active review from `git rev-parse --show-toplevel` and `git branch --show-current`, using the same slug and highest-`n` rule as Task 4.
- **Seen state.** It's kept in `${XDG_STATE_HOME:-~/.local/state}/review-watch/<sha1 of FILE path>`, one `commentid:lastusermsgid` per line.
- **Loop.** Every `interval` seconds (default 2), run `jq -r '.comments[] | select(.status=="POSTED" and (.deleted|not)) | "\(.id):\([.thread[]|select(.author=="user" and (.draft|not))][-1].id)"'`.
- **Output.** When any key isn't yet seen, print those comment ids one per line, record them as seen, and exit 0. With `--once`, check once and exit 1 if there's nothing new.
- **Errors.** Exit 2, with a message on stderr, when there's no review file or the JSON is invalid.

**SKILL.md** has frontmatter with `name: review-comments`. Its description: "Use when working through Robert's Neovim review comments in .review/*.json, or when asked to watch, answer, or address review comments." The body covers:
- **The file.** Its location, schema, and status table, copied from the spec.
- **The loop.** Run `review-watch` in the background (Monitor, or background Bash). When it exits, read the file and handle each printed comment id, then restart the watcher.
- **Per comment.** Find the code by `snippet` first and by `line_start` second. Judge from the wording whether it's a question or a change request. Answer questions directly. For changes, edit the working tree, don't commit, and explain the change in the reply.
- **Writing back.** Append one message: `{ "id": "m_<6 hex>", "author": "agent", "body": ..., "at": <UTC ISO> }`. Set `status` to `"RESPONDED"` and `updated_at`. Write atomically with `jq ... > file.tmp && mv file.tmp file`, re-reading right before writing. Never touch other fields, PENDING comments, drafts, or RESOLVED status.
- **If a comment is ambiguous,** ask in the reply rather than guessing.

- [ ] **Step 1: Write the failing test** `review_watch_test.sh`. In a temp git repo on branch `feat/x`:
  1. Write `.review/2026-11-25-feat-x-1.json` with one POSTED comment.
  2. `review-watch --once` prints `c_aaaaaa` and exits 0.
  3. It exits 1 the second time.
  4. Add a non-draft user message to that comment. It prints the id again.
  5. Point it at a PENDING-only file. It exits 1.
  6. Point it at invalid JSON. It exits 2.
- [ ] **Step 2:** Run `bash $P/tests/review_watch_test.sh`. Expected: FAIL. **Step 3:** Implement the script. **Step 4:** Run it. Expected: `ALL PASS`.
- [ ] **Step 5:** Write `SKILL.md`. Check that `ls ~/.claude/skills/review-comments/SKILL.md` exists and the frontmatter parses (`head -5`).
- [ ] **Step 6: Manual check.** In a Claude Code session in `~/path/to/repo`, after posting a comment in Neovim, ask "watch my review comments". The agent starts `review-watch`, replies, and the reply shows up in Neovim.
- [ ] **Step 7:** Commit the test into `$P` with `feat: review-watch script and agent skill`. The script and skill live outside the repo; note their paths in `$P/README.md`, created here, which also covers keymaps and config.
