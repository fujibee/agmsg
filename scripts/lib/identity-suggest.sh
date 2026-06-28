#!/usr/bin/env bash
# identity-suggest.sh — default names for first-time joins.

agmsg_suggest_slug() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:space:]/\\' '---' | sed 's/--*/-/g; s/^-//; s/-$//')"
  printf '%s\n' "${value:-team}"
}

agmsg_suggested_agent() {
  local type="$1" suggested
  suggested="$(agmsg_type_get "$type" suggested_agent "$type")"
  agmsg_suggest_slug "$suggested"
}

agmsg_suggested_team() {
  local project_path="${1%/}"
  local worktree_name parent_dir parent_name grandparent_name

  worktree_name="$(basename "$project_path")"
  parent_dir="$(dirname "$project_path")"
  parent_name="$(basename "$parent_dir")"
  grandparent_name="$(basename "$(dirname "$parent_dir")")"

  if [ "$grandparent_name" = "worktrees" ] && [ -n "$parent_name" ]; then
    agmsg_suggest_slug "$parent_name-$worktree_name"
  else
    agmsg_suggest_slug "$worktree_name"
  fi
}
