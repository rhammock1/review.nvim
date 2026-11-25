---
name: review-comments
description: Work through the user's inline code-review comments left in Neovim (review.nvim) — read .review/*.json in the repo, answer questions, make requested changes, and write replies back into the thread. Use when the user says "watch my review comments", "address my review", "answer my review comments", "/review-comments", or mentions the .review folder or review.nvim.
---

# Review comments

The user reviews diffs in Neovim (diffview) and leaves inline comments with review.nvim. They land in a JSON file in the repo. Your job: pick up comments they have **posted**, answer or address each one, and reply in that comment's thread. Neovim watches the file and shows your replies next to the code, so they never have to leave the editor.

## The file

`<repo toplevel>/.review/YYYY-MM-DD-<branch, / replaced by ->-<n>.json`. The active review for a branch is the one with the highest `n`. It's git-ignored through `.git/info/exclude`.

```json
{
  "version": 1, "branch": "feat/x", "base": "<sha or null>", "number": 1, "created_at": "…",
  "comments": [{
    "id": "c_7f3a9b", "status": "POSTED",
    "path": "src/orders/sync.js", "side": "new", "commit": "<sha>", "worktree": true,
    "line_start": 42, "line_end": 48, "snippet": "exact code that was selected",
    "created_at": "…", "updated_at": "…",
    "thread": [
      { "id": "m_01ab23", "author": "user",  "body": "Why is this nullable?", "at": "…" },
      { "id": "m_9f8e7d", "author": "agent", "body": "Because …",             "at": "…" }
    ]
  }]
}
```

- `side`: `"new"` means the code as it is now (the working tree when `worktree` is true). `"old"` means the pre-change code, i.e. lines the branch deleted or changed. For `old`, read the file at the comment's own `commit`, which is the left side's revision: `git show <commit>:<path>`. The top-level `base` is informational and may be null.
- `deleted: true` marks a tombstone. Ignore it.
- `draft: true` on a message means the user hasn't sent it yet. Ignore it.

| Status | Set by | Meaning |
|---|---|---|
| `PENDING` | the user | Draft. **Don't touch it.** |
| `POSTED` | the user | Ready for you. This includes a follow-up reply on a thread you already answered. |
| `RESPONDED` | you | You replied. |
| `RESOLVED` | the user | Done. Never set or change this yourself. |

## The loop

1. Start the watcher in the background from the repo: `scripts/review-watch`, in this skill's directory. It isn't on your PATH, so call it by its full path, but keep the repo as the working directory. Run it with the Monitor tool or as a background Bash command. It blocks until something new is posted, then prints the comment ids, one per line, and exits 0. Exit 2 means there's no review file yet or the JSON is invalid. Tell the user, wait a bit, and retry.
   - `scripts/review-watch --once` checks a single time and doesn't block. It exits 1 if there's nothing new.
   - Pass a file path to watch a specific review.
2. When it exits, re-read the file and handle each printed id, as described below.
3. Start `scripts/review-watch` again. Keep going until the user says stop.

If the user asks for a one-off pass ("answer my review comments"), skip the watcher. Handle every `POSTED` comment whose last non-draft message is from `user`.

## Handling one comment

- **Find the code by `snippet` first,** using `line_start` only as a hint. Lines drift as code changes.
- **Read the whole thread,** not just the last message. A follow-up builds on your earlier answer.
- **Work out the intent from the wording.** There's no type field.
  - **Question:** answer it directly and concisely. Cite file:line where it helps.
  - **Change request:** make the change in the working tree. Don't commit unless the user asked you to. Then reply with what you changed and where. The diffview `--imply-local` right side shows your edit live.
  - **Ambiguous:** ask a short clarifying question in the reply rather than guessing.
- **Keep replies short and plain.** The user reads them in a small float next to the code.

## Writing back (exact rules)

Neovim writes this file too, so:

1. **Re-read the file immediately before writing.** Never write from a stale copy.
2. **Only change these fields** on the comments you're answering:
   - Append one message: `{ "id": "m_<6 random hex>", "author": "agent", "body": "…", "at": "<UTC now, YYYY-MM-DDTHH:MM:SSZ>" }`
   - Set `"status": "RESPONDED"` and `"updated_at"` to the same UTC timestamp.

   Don't modify, reorder, or delete anything else: no other comments, no user messages, no locations, snippets or top-level fields.
3. **Write atomically:** write a temp file in the same directory, then `mv` it over the original. With jq:

```bash
f=.review/2026-11-25-feat-x-1.json
now=$(date -u +%Y-%m-%dT%H:%M:%SZ); mid="m_$(openssl rand -hex 3)"
jq --arg id "c_7f3a9b" --arg mid "$mid" --arg now "$now" --arg body "Your reply here" '
  .comments |= map(if .id == $id then
    .thread += [{id: $mid, author: "agent", body: $body, at: $now}]
    | .status = "RESPONDED" | .updated_at = $now
  else . end)' "$f" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"
```

Handle comments one at a time, so each reply appears in Neovim as soon as it's ready.

## Don't

- Act on `PENDING` comments or draft messages.
- Resolve comments or edit the user's text.
- Post anything to GitHub. These comments are local only.
