#!/usr/bin/env bash
# Where every team's store is, in one bash, by calling agmsg-core's own functions. The rules for where a
# store lives are the core's (storage.sh, driver-registry.sh, validate.sh); this only asks them once per team
# instead of starting `api.sh` once per team. One line per team:
#   <team> TAB <storage driver> TAB <store path> TAB <true|false: the store exists>
# Any failure ends the whole run with a non-zero exit, so the caller never keeps a partial answer.
SCRIPT_DIR="$1/scripts"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/storage.sh" || exit 1
agmsg_storage_load || exit 1
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh" || exit 1
driver="$(agmsg_storage_driver)" || exit 1
for dir in "$SCRIPT_DIR/../teams"/*/; do
  [ -f "${dir}config.json" ] || continue
  team="${dir%/}"
  team="${team##*/}"
  path="$(agmsg_db_path "$team")" || exit 1
  if [ -e "$path" ]; then exists=true; else exists=false; fi
  printf '%s\t%s\t%s\t%s\n' "$team" "$driver" "$path" "$exists"
done
