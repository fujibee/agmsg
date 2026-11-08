#!/usr/bin/env bash
# update-command.sh -- the command a person types to update THIS install.
#
# The channel comes from the install's own VERSION: a prerelease version (it has
# a `-` after the git-describe provenance is dropped, such as 1.8.0-rc.1) updates from @next, a stable one from @latest, so a
# stable install is never pointed at a prerelease. A named install (its directory
# is not "agmsg") adds --cmd <name>, since several installs on a machine would
# otherwise be ambiguous.
#
#   agmsg_update_command <skill dir>   prints e.g. `npx agmsg@latest install --update`
#
# Reads one file with builtins; starts no process.
agmsg_update_command() {   # <skill dir>
  local skill="${1%/}" name version tag=latest
  name="${skill##*/}"
  if [ -f "$skill/VERSION" ]; then
    IFS= read -r version < "$skill/VERSION" || true
    version="${version%$'\r'}"
    # `git describe` provenance (-<n>-g<hash>, -dirty) says where a build came
    # from, not which channel it is on.
    version="${version%-dirty}"
    case "$version" in *-[0-9]*-g[0-9a-f]*) version="${version%-[0-9]*-g[0-9a-f]*}" ;; esac
    case "$version" in *-*) tag=next ;; esac
  fi
  printf 'npx agmsg@%s install --update' "$tag"
  [ "$name" = agmsg ] || printf ' --cmd %s' "$name"
}
