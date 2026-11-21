#!/usr/bin/env bash
# Fetch the newest earlier attempt's results record for one bats shard.
#
#   fetch-prior-bats-results.sh <os> <shard> <current-attempt> <out-file>
#
# Needs GH_TOKEN, GITHUB_REPOSITORY and GITHUB_RUN_ID (and `actions: read`). A
# rerun of only the failed jobs leaves the green shards without a record of that
# attempt, so this looks back from attempt N-1 to 1 and takes the newest record
# there is. Anything that goes wrong -- no artifact, an API error, an expired
# artifact, a download failure -- leaves <out-file> absent and exits 0: the caller
# then runs the whole shard. It never decides to skip anything itself.
set -u

[ "$#" -eq 4 ] || { echo "usage: ${0##*/} <os> <shard> <attempt> <out-file>" >&2; exit 2; }
os="$1"; shard="$2"; attempt="$3"; out="$4"
rm -f -- "$out"

case "$attempt" in ''|*[!0-9]*) echo "${0##*/}: attempt '$attempt' is not a number; running the whole shard"; exit 0 ;; esac
[ "$attempt" -gt 1 ] || exit 0
: "${GITHUB_REPOSITORY:?}" "${GITHUB_RUN_ID:?}"

names="$(gh api --paginate "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/artifacts?per_page=100" \
  --jq '.artifacts[] | select(.expired | not) | .name' 2>/dev/null)" || {
  echo "${0##*/}: could not list this run's artifacts; running the whole shard"
  exit 0
}

n=$((attempt - 1))
while [ "$n" -ge 1 ]; do
  name="bats-results-$os-$shard-a$n"
  if printf '%s\n' "$names" | grep -Fxq -- "$name"; then
    dir="$(mktemp -d)"
    if gh run download "$GITHUB_RUN_ID" --repo "$GITHUB_REPOSITORY" -n "$name" -D "$dir" >/dev/null 2>&1 \
       && [ -s "$dir/bats-results.tsv" ]; then
      cp -- "$dir/bats-results.tsv" "$out"
      echo "${0##*/}: using the results of attempt $n ($name)"
    else
      echo "${0##*/}: could not download $name; running the whole shard"
    fi
    rm -f -- "$dir/bats-results.tsv"
    rmdir -- "$dir" 2>/dev/null || true
    exit 0
  fi
  n=$((n - 1))
done
echo "${0##*/}: no earlier attempt left a results record for $os shard $shard; running the whole shard"
exit 0
