#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
source "$SCRIPT_DIR/lib/node.sh"

command="${1:?Usage: inbox-transport.sh peek|ack TEAM AGENT}"
team="${2:?Missing team}"
agent="${3:?Missing agent}"
agmsg_storage_load

case "$command" in
  peek)
    storage_store_exists "$team" || exit 0
    storage_list_unread "$team" "$agent"
    ;;
  ack)
    node_bin="$(agmsg_resolve_node)"
    id_lines="$("$node_bin" -e '
      let input = "";
      process.stdin.on("data", chunk => input += chunk);
      process.stdin.on("end", () => {
        const ids = JSON.parse(input);
        if (!Array.isArray(ids) || ids.length === 0 ||
            ids.some(id => typeof id !== "string" || !id || /[\r\n]/.test(id))) process.exit(2);
        process.stdout.write(ids.join("\n"));
      });
    ')"
    ids=()
    while IFS= read -r id; do
      [ -n "$id" ] && ids+=("$id")
    done <<< "$id_lines"
    [ "${#ids[@]}" -gt 0 ]
    storage_mark_read_batch "$team" "$agent" "${ids[@]}"
    ;;
  *) echo "Unknown command: $command" >&2; exit 64 ;;
esac
