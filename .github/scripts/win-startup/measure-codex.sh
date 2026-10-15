#!/usr/bin/env bash
# #1613: time from launching `codex` through the agmsg PATH shim until the
# (fake) TUI is exec'd, for several refs, alternating so drift hits all of them.
#
# usage: measure-codex.sh <repo> <ref> [<ref> ...]
# Needs: git, node, sqlite3, a bash with EPOCHREALTIME (Git Bash and bash 5 have it).
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$here/common.sh"
repo="$1"; shift
refs=("$@")
runs="${RUNS:-3}"
work="${WORK:-$(mktemp -d)}"
mkdir -p "$work"

# A fake `codex`: --version, an app-server that prints the banner and listens
# (node, so it also runs where python is not on PATH), and anything else is "the TUI".
cat > "$work/listener.js" <<'EOF'
const net = require('net');
const s = net.createServer((c) => c.destroy());
s.listen(0, '127.0.0.1', () => {
  console.log('codex app-server (WebSockets)');
  console.log('  listening on: ws://127.0.0.1:' + s.address().port);
});
setTimeout(() => process.exit(0), 90000);
EOF
mkdir -p "$work/real"
cat > "$work/real/codex" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  --version) echo "codex-cli 0.162.1"; exit 0 ;;
  app-server)
    node "$work/listener.js" &
    child=\$!
    trap 'kill "\$child" 2>/dev/null' TERM INT
    wait "\$child"
    ;;
  *) date +%s.%N > "\$TUI_FILE" ;;
esac
EOF
chmod +x "$work/real/codex"

# The shim is installed as a COPY (a symlink made by `ln -s` on Git Bash is a
# copy that loses its place in the skill tree), and told where the scripts are.
export AGMSG_CODEX_SHIM_WRAPPER=1

declare -A results
for r in $(seq 1 "$runs"); do
  for ref in "${refs[@]}"; do
    id="$(printf '%s' "$ref" | tr '/.' '__')"
    skill="$work/skill-$id-$r"
    mkdir -p "$work/bin-$id-$r"
    make_skill "$repo" "$ref" "$skill"
    export AGMSG_STORAGE_PATH="$skill/store" AGMSG_SELF_NAME=off CODEX_HOME="$work/codexhome-$id-$r"
    export AGMSG_CODEX_SHIM_SCRIPT_DIR="$skill/scripts/drivers/types/codex"
    mkdir -p "$CODEX_HOME"
    cp "$skill/scripts/drivers/types/codex/codex-shim.sh" "$work/bin-$id-$r/codex"
    chmod +x "$work/bin-$id-$r/codex"
    P="$work/bin-$id-$r:$work/real:$PATH"

    # Two fresh projects per ref and run, each launched 3 times in a row with the
    # same CODEX_HOME: one untraced (timing), one traced (counting; xtrace itself
    # costs on Windows, so its times are not reported).
    for kind in timed traced; do
      proj="$work/proj-$id-$r-$kind"
      mkdir -p "$proj"
      bash "$skill/scripts/join.sh" ci "seat-$kind" codex "$proj" >/dev/null 2>&1
      PATH="$P" bash "$skill/scripts/delivery.sh" set monitor codex "$proj" >/dev/null 2>&1
      for n in 1 2 3; do
        export TUI_FILE="$work/tui-$id-$r-$kind-$n"
        rm -f "$TUI_FILE"
        if [ "$kind" = timed ]; then
          a=$(now)
          ( cd "$proj" && env PATH="$P" codex ) >/dev/null 2>&1
          if [ -f "$TUI_FILE" ]; then t=$(elapsed "$a" "$(cat "$TUI_FILE")"); else t="no-TUI"; fi
          echo "run $r  $ref  launch $n (untraced): ${t}s"
          results["$ref#$n"]+="$t "
        else
          trace="$work/trace-$id-$r-$n.log"
          ( cd "$proj" && env PATH="$P" SHELLOPTS=xtrace PS4='+T ${EPOCHREALTIME} ${BASH_SOURCE##*/}:${LINENO} ' codex ) 2> "$trace" >/dev/null
          ns=$(grep -c 'delivery\.sh status' "$trace" || true)
          nm=$(grep -c 'delivery\.sh set monitor' "$trace" || true)
          if [ "$ns" -ge 1 ]; then v=counted; else v=DISCARDED; fi
          echo "run $r  $ref  launch $n (traced): delivery status x$ns, set monitor x$nm -> $v"
          if [ "$v" = counted ]; then
            results["st:$ref#$n"]+="$ns "
            results["sm:$ref#$n"]+="$nm "
          else
            results["drop:$ref"]+="r$r/l$n "
          fi
          grep -m1 'broken install' "$trace" >/dev/null 2>&1 && echo "  (shim fell through: broken install warning)"
        fi
      done
    done
  done
done

summary "### #1613 codex launch through the shim (windows-latest, fake codex, 3 consecutive launches per project, same CODEX_HOME)"
summary "| ref | launch # | launch s (median, untraced) | all runs | delivery status per launch | set monitor per launch |"
summary "| --- | ---: | ---: | --- | --- | --- |"
for ref in "${refs[@]}"; do
  for n in 1 2 3; do
    m=$(printf '%s\n' ${results["$ref#$n"]} | grep -E '^[0-9.]+$' | median)
    summary "| $ref | $n | $m | ${results["$ref#$n"]} | ${results["st:$ref#$n"]:-none} | ${results["sm:$ref#$n"]:-none} |"
  done
  summary "Discarded traced launches for $ref (no delivery status in the trace): ${results["drop:$ref"]:-none}"
done
