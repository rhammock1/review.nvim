#!/usr/bin/env bash
# Tests for the skill's review-watch. Usage: bash tests/review_watch_test.sh [path/to/review-watch]
set -u
RW="${1:-$(cd "$(dirname "$0")/.." && pwd)/skills/review-comments/scripts/review-watch}"
fail=0
check() { # name expected_code expected_stdout actual_code actual_stdout
  if [[ "$2" != "$4" || "$3" != "$5" ]]; then
    echo "FAIL: $1 (want code=$2 out='$3', got code=$4 out='$5')"; fail=1
  else
    echo "ok: $1"
  fi
}

tmp=$(mktemp -d); export XDG_STATE_HOME="$tmp/state"
repo="$tmp/repo"; mkdir -p "$repo/.review"; cd "$repo"
git init -q -b feat/x; git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
f="$repo/.review/2026-11-25-feat-x-1.json"
cat > "$f" <<'JSON'
{ "version": 1, "branch": "feat/x", "number": 1, "comments": [
  { "id": "c_aaaaaa", "status": "POSTED", "thread": [ { "id": "m_000001", "author": "user", "body": "q", "at": "1" } ] },
  { "id": "c_bbbbbb", "status": "PENDING", "thread": [ { "id": "m_000002", "author": "user", "body": "draft", "at": "1" } ] },
  { "id": "c_cccccc", "status": "POSTED", "deleted": true, "thread": [ { "id": "m_000003", "author": "user", "body": "gone", "at": "1" } ] }
] }
JSON

out=$("$RW" --once); check "first run reports posted (active file)" 0 "c_aaaaaa" $? "$out"
out=$("$RW" --once); check "second run nothing new" 1 "" $? "$out"

jq '.comments[0].thread += [{"id":"m_agent1","author":"agent","body":"a","at":"2"},{"id":"m_000004","author":"user","body":"more","at":"3"}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
out=$("$RW" --once "$f"); check "follow-up reply re-reports" 0 "c_aaaaaa" $? "$out"

jq '.comments[0].thread += [{"id":"m_000005","author":"user","body":"d","at":"4","draft":true}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
out=$("$RW" --once "$f"); check "draft reply ignored" 1 "" $? "$out"

p="$repo/.review/pending.json"
echo '{"comments":[{"id":"c_dddddd","status":"PENDING","thread":[{"id":"m_9","author":"user","body":"x","at":"1"}]}]}' > "$p"
out=$("$RW" --once "$p"); check "pending only" 1 "" $? "$out"

echo '{oops' > "$repo/.review/bad.json"
out=$("$RW" --once "$repo/.review/bad.json" 2>/dev/null); check "invalid json" 2 "" $? "$out"

out=$("$RW" --once "$repo/.review/missing.json" 2>/dev/null); check "missing file" 2 "" $? "$out"

# blocking mode: exits when a new posted comment appears
jq '.comments[1].status = "POSTED"' "$f" > "$f.tmp"
( sleep 1; mv "$f.tmp" "$f" ) &
out=$(timeout 10 "$RW" --interval 0.2 "$f"); check "blocking mode wakes on new post" 0 "c_bbbbbb" $? "$out"

# a branch sharing the prefix (feat/x-extra → feat-x-extra) must not hijack feat/x's active file
echo '{"comments":[{"id":"c_eeeeee","status":"POSTED","thread":[{"id":"m_e","author":"user","body":"x","at":"1"}]}]}' > "$repo/.review/2026-11-25-feat-x-extra-5.json"
echo '{"comments":[{"id":"c_ffffff","status":"POSTED","thread":[{"id":"m_f","author":"user","body":"x","at":"1"}]}]}' > "$repo/.review/2026-11-26-feat-x-2.json"
out=$("$RW" --once); check "active file ignores prefix-sharing branch" 0 "c_ffffff" $? "$out"

# comment without a thread is tolerated (hand edit)
echo '{"comments":[{"id":"c_nothrd","status":"POSTED"}]}' > "$repo/.review/nothread.json"
out=$("$RW" --once "$repo/.review/nothread.json"); check "missing thread tolerated" 0 "c_nothrd" $? "$out"

# without shasum, fall back to sha1sum, then cksum
tools="$tmp/tools"; mkdir -p "$tools"
for t in bash jq grep mkdir touch cut dirname basename cksum cat; do ln -s "$(command -v "$t")" "$tools/$t"; done
echo '{"comments":[{"id":"c_hashed","status":"POSTED"}]}' > "$repo/.review/hash.json"
run_bare() { PATH="$tools" XDG_STATE_HOME="$tmp/$1" "$tools/bash" "$RW" --once "$repo/.review/hash.json" 2>&1; }
out=$(run_bare bare); check "cksum fallback" 0 "c_hashed" $? "$out"
out=$(run_bare bare); check "cksum fallback remembers" 1 "" $? "$out"
[[ -n "$(ls -A "$tmp/bare/review-watch")" ]] && n=yes || n=no; check "cksum fallback names its state file" 0 yes 0 "$n"
printf '#!%s\ncat >/dev/null\necho "fakesha1  -"\n' "$tools/bash" > "$tools/sha1sum"; chmod +x "$tools/sha1sum"
out=$(run_bare sha1); check "sha1sum fallback" 0 "c_hashed" $? "$out"
check "sha1sum fallback names its state file" 0 fakesha1 0 "$(ls -A "$tmp/sha1/review-watch")"

rm -rf "$tmp"
[[ $fail == 0 ]] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
