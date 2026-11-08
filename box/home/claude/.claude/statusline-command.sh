#!/bin/bash
# Statusline: model | repo:branch | context % | weekly limit %
input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name // "?"')
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
repo=$(echo "$input" | jq -r '.workspace.repo | if . then .name else empty end')
ctx=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
week=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

branch=""
if [ -n "$cwd" ] && git -C "$cwd" --no-optional-locks rev-parse --git-dir >/dev/null 2>&1; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null \
    || git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  [ -z "$repo" ] && repo=$(basename "$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)")
fi
[ -z "$repo" ] && repo="-"
[ -z "$branch" ] && branch="-"

ctxs="--"
[ -n "$ctx" ] && ctxs=$(printf '%.0f%%' "$ctx")
weeks="--"
[ -n "$week" ] && weeks=$(printf '%.0f%%' "$week")

printf '\033[36m%s\033[0m | \033[33m%s\033[0m:\033[32m%s\033[0m | ctx %s | 7d %s' \
  "$model" "$repo" "$branch" "$ctxs" "$weeks"
