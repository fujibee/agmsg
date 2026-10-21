#!/usr/bin/env bats

# plugin.sh install / update / remove (#1594). The "GitHub" is a local bare
# repository: AGMSG_PLUGIN_GIT_BASE points the clone URL at file://$GIT_BASE, so
# nothing here touches the network.

load test_helper

setup() {
  setup_test_env
  export GIT_BASE="$BATS_TEST_TMPDIR/gitbase"
  export AGMSG_PLUGIN_GIT_BASE="file://$GIT_BASE"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  printf 'v1.6.0-rc.6-3-gabc123\n' > "$TEST_SKILL_DIR/VERSION"
  mkdir -p "$GIT_BASE"
}
teardown() { teardown_test_env; }

PLUGIN() { bash "$SCRIPTS/plugin.sh" "$@"; }

# mk_repo <owner> <repo> [min_core] -- a work tree with one type, one ext-tool
# and an unrelated docs/ dir, committed, with a bare copy at $GIT_BASE/<o>/<r>.git
mk_repo() {
  local o="$1" r="$2" min="${3:-}" w="$BATS_TEST_TMPDIR/work-$1-$2"
  mkdir -p "$w/types/fx" "$w/ext-tools/tq" "$w/docs" "$GIT_BASE/$o"
  git -C "$w" init -q -b main 2>/dev/null || git -C "$w" init -q
  printf 'name=%s\ndescription=demo plugin\n%s' "$r" "${min:+min_core=$min
}" > "$w/agmsg-plugin.conf"
  printf 'name=fx\ntemplate=template.md\nhooks_file=.x/fx.json\n' > "$w/types/fx/type.conf"
  printf '# t\n' > "$w/types/fx/template.md"
  printf 'timeout=5\n' > "$w/ext-tools/tq/tool.conf"
  printf '#!/usr/bin/env bash\necho v1\n' > "$w/ext-tools/tq/handle"
  chmod +x "$w/ext-tools/tq/handle"
  echo docs > "$w/docs/a.md"
  git -C "$w" add -A
  git -C "$w" commit -qm one
  git clone -q --bare "$w" "$GIT_BASE/$o/$r.git"
  git -C "$GIT_BASE/$o/$r.git" config uploadpack.allowAnySHA1InWant true
  echo "$w"
}

# push a second commit that changes the handle
bump_repo() {
  local o="$1" r="$2" w="$BATS_TEST_TMPDIR/work-$1-$2"
  printf '#!/usr/bin/env bash\necho v2\n' > "$w/ext-tools/tq/handle"
  git -C "$w" commit -qam two
  git -C "$w" push -q "$GIT_BASE/$o/$r.git" HEAD:main 2>/dev/null \
    || git -C "$w" push -q "$GIT_BASE/$o/$r.git" HEAD
}

head_of() { git -C "$GIT_BASE/$1/$2.git" rev-parse HEAD; }

@test "install without --yes and without a TTY prints the report and exits 3, installing nothing" {
  mk_repo acme pack >/dev/null
  run PLUGIN install acme/pack
  [ "$status" -eq 3 ]
  grep -q "Plugin source: github/acme/pack" <<<"$output"
  grep -q "$(head_of acme pack)" <<<"$output"
  grep -q "types/fx" <<<"$output"
  grep -q "ext-tools/tq/handle" <<<"$output"
  grep -q "at your own risk" <<<"$output"
  grep -q "Ignored (not installed.*): docs/" <<<"$output"
  grep -q "plugin install acme/pack@$(head_of acme pack) --yes" <<<"$output"
  [ ! -e "$TEST_SKILL_DIR/db/plugin-sources" ]
  [ ! -e "$TEST_SKILL_DIR/plugins/sources/github" ]
  [ ! -s "$TEST_SKILL_DIR/db/trusted-plugins" ]
}

@test "install --yes places the commit, records it, and trusts every driver at that path" {
  mk_repo acme pack >/dev/null
  sha="$(head_of acme pack)"
  run PLUGIN install acme/pack --yes
  [ "$status" -eq 0 ]
  d="$TEST_SKILL_DIR/plugins/sources/github/acme/pack/$sha"
  [ -f "$d/types/fx/type.conf" ]
  [ ! -e "$d/.git" ]
  [ "$(cut -f1 "$TEST_SKILL_DIR/db/plugin-sources")" = "github/acme/pack" ]
  [ "$(cut -f2 "$TEST_SKILL_DIR/db/plugin-sources")" = "acme/pack" ]
  [ "$(cut -f3 "$TEST_SKILL_DIR/db/plugin-sources")" = "$sha" ]
  [ "$(cut -f4 "$TEST_SKILL_DIR/db/plugin-sources")" = "$d" ]
  grep -qxF "$(printf 'types/fx\t%s' "$d/types/fx")" "$TEST_SKILL_DIR/db/trusted-plugins"
  grep -qxF "$(printf 'ext-tools/tq\t%s' "$d/ext-tools/tq")" "$TEST_SKILL_DIR/db/trusted-plugins"
  # and the registry resolves it
  run bash -c "source '$SCRIPTS/lib/driver-registry.sh'; agmsg_ext_tool_dir tq"
  [ "$status" -eq 0 ]
  [ "$output" = "$d/ext-tools/tq" ]
  [ ! -d "$TEST_SKILL_DIR/plugins/sources/.staging" ] || [ -z "$(ls -A "$TEST_SKILL_DIR/plugins/sources/.staging")" ]
}

@test "list shows the source and short commit for an installed driver, - for others" {
  mk_repo acme pack >/dev/null
  PLUGIN install acme/pack --yes >/dev/null
  run PLUGIN list
  line="$(grep '^types/fx ' <<<"$output")"
  grep -q "github/acme/pack" <<<"$line"
  grep -q "$(head_of acme pack | cut -c1-12)" <<<"$line"
  grep -q "^SOURCE\|SOURCE" <<<"$(PLUGIN list | head -1)"
}

@test "install @<full sha> pins that commit even after the branch moves" {
  mk_repo acme pack >/dev/null
  old="$(head_of acme pack)"
  bump_repo acme pack
  [ "$(head_of acme pack)" != "$old" ]
  run PLUGIN install "acme/pack@$old" --yes
  [ "$status" -eq 0 ]
  [ -f "$TEST_SKILL_DIR/plugins/sources/github/acme/pack/$old/ext-tools/tq/handle" ]
  grep -q "echo v1" "$TEST_SKILL_DIR/plugins/sources/github/acme/pack/$old/ext-tools/tq/handle"
}

@test "install @<branch> checks out that branch" {
  w="$(mk_repo acme pack)"
  git -C "$w" checkout -q -b other
  printf '#!/usr/bin/env bash\necho other\n' > "$w/ext-tools/tq/handle"
  git -C "$w" commit -qam other
  git -C "$w" push -q "$GIT_BASE/acme/pack.git" other
  run PLUGIN install acme/pack@other --yes
  [ "$status" -eq 0 ]
  grep -q "echo other" "$TEST_SKILL_DIR"/plugins/sources/github/acme/pack/*/ext-tools/tq/handle
  [ "$(cut -f2 "$TEST_SKILL_DIR/db/plugin-sources")" = "acme/pack@other" ]
}

@test "the checkout is not CRLF-converted" {
  w="$(mk_repo acme pack)"
  printf '#!/usr/bin/env bash\necho crlf\n' > "$w/ext-tools/tq/handle"
  git -C "$w" commit -qam lf
  git -C "$w" push -q "$GIT_BASE/acme/pack.git" HEAD:main 2>/dev/null || git -C "$w" push -q "$GIT_BASE/acme/pack.git" HEAD
  # a user-level autocrlf=true would convert; the install must override it
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  printf '[core]\n\tautocrlf = true\n\teol = crlf\n' > "$GIT_CONFIG_GLOBAL"
  run PLUGIN install acme/pack --yes
  [ "$status" -eq 0 ]
  h="$(ls "$TEST_SKILL_DIR"/plugins/sources/github/acme/pack/*/ext-tools/tq/handle)"
  [ -z "$(grep -c "$(printf '\r')" "$h" | grep -v '^0$')" ]
}

@test "a repository without agmsg-plugin.conf is refused" {
  w="$(mk_repo acme pack)"
  git -C "$w" rm -q agmsg-plugin.conf
  git -C "$w" commit -qm noconf
  git -C "$w" push -q "$GIT_BASE/acme/pack.git" HEAD:main 2>/dev/null || git -C "$w" push -q "$GIT_BASE/acme/pack.git" HEAD
  run PLUGIN install acme/pack --yes
  [ "$status" -eq 1 ]
  grep -q "no agmsg-plugin.conf" <<<"$output"
  [ ! -e "$TEST_SKILL_DIR/db/plugin-sources" ]
}

@test "min_core newer than the running core is refused; an older one installs" {
  mk_repo acme pack 9.0.0 >/dev/null
  run PLUGIN install acme/pack --yes
  [ "$status" -eq 1 ]
  grep -q "needs agmsg 9.0.0 or newer; this installation is 1.6.0" <<<"$output"
  [ ! -e "$TEST_SKILL_DIR/db/plugin-sources" ]
  mk_repo acme ok 1.5.0 >/dev/null
  run PLUGIN install acme/ok --yes
  [ "$status" -eq 0 ]
}

@test "a driver name outside [a-z0-9-] is refused" {
  w="$(mk_repo acme pack)"
  mkdir -p "$w/types/Bad_Name"
  printf 'name=x\n' > "$w/types/Bad_Name/type.conf"
  git -C "$w" add -A; git -C "$w" commit -qm bad
  git -C "$w" push -q "$GIT_BASE/acme/pack.git" HEAD:main 2>/dev/null || git -C "$w" push -q "$GIT_BASE/acme/pack.git" HEAD
  run PLUGIN install acme/pack --yes
  [ "$status" -eq 1 ]
  grep -q "lowercase letters, digits" <<<"$output"
}

@test "owner and repo are validated as single path segments" {
  for bad in '../x/y' 'a/..' 'a/b/c' '/a/b' 'a' 'a/-b' '-a/b' 'a/b@' 'a/b@../x' 'a b/c'; do
    run PLUGIN install "$bad" --yes
    [ "$status" -ne 0 ]
    [ "$status" -ne 3 ]
  done
  [ ! -e "$TEST_SKILL_DIR/db/plugin-sources" ]
}

@test "a driver that shares a built-in's name is refused without --override, with the full explanation" {
  mk_repo acme pack >/dev/null
  mkdir -p "$SCRIPTS/drivers/types/fx"
  printf 'name=fx\n' > "$SCRIPTS/drivers/types/fx/type.conf"
  run PLUGIN install acme/pack --yes
  [ "$status" -eq 1 ]
  grep -q "would replace built-in" <<<"$output"
  grep -q "types/fx" <<<"$output"
  grep -q "Every team on this machine" <<<"$output"
  grep -q "plugin remove acme/pack" <<<"$output"
  grep -q "agmsg plugin install acme/pack --override" <<<"$output"
  [ ! -e "$TEST_SKILL_DIR/db/plugin-sources" ]
  run PLUGIN install acme/pack --yes --override
  [ "$status" -eq 0 ]
  d="$(cut -f4 "$TEST_SKILL_DIR/db/plugin-sources")"
  [ "$(bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_dir fx 2>/dev/null")" = "$d/types/fx" ]
}

@test "remove of an overriding plugin says the built-in is back" {
  mk_repo acme pack >/dev/null
  mkdir -p "$SCRIPTS/drivers/types/fx"
  printf 'name=fx\n' > "$SCRIPTS/drivers/types/fx/type.conf"
  PLUGIN install acme/pack --yes --override >/dev/null
  run PLUGIN remove acme/pack
  [ "$status" -eq 0 ]
  grep -q "built-in driver(s) are back in use: types/fx" <<<"$output"
}

@test "a second source with the same <axis>/<name> is refused, naming both" {
  mk_repo acme pack >/dev/null
  mk_repo other pack2 >/dev/null
  PLUGIN install acme/pack --yes >/dev/null
  run PLUGIN install other/pack2 --yes
  [ "$status" -eq 1 ]
  grep -q "github/other/pack2 clashes" <<<"$output"
  grep -q "already provided by github/acme/pack" <<<"$output"
  [ "$(wc -l < "$TEST_SKILL_DIR/db/plugin-sources" | tr -d ' ')" -eq 1 ]
}

@test "a driver already placed by hand under plugins/ is also a clash" {
  mk_repo acme pack >/dev/null
  mkdir -p "$TEST_SKILL_DIR/plugins/types/fx"
  printf 'name=fx\n' > "$TEST_SKILL_DIR/plugins/types/fx/type.conf"
  run PLUGIN install acme/pack --yes
  [ "$status" -eq 1 ]
  grep -q "placed by hand" <<<"$output"
}

@test "installing a source that is already installed points at update" {
  mk_repo acme pack >/dev/null
  PLUGIN install acme/pack --yes >/dev/null
  run PLUGIN install acme/pack --yes
  [ "$status" -eq 1 ]
  grep -q "already installed" <<<"$output"
}

@test "update: same commit says up to date and changes nothing" {
  mk_repo acme pack >/dev/null
  PLUGIN install acme/pack --yes >/dev/null
  before="$(cat "$TEST_SKILL_DIR/db/plugin-sources")"
  run PLUGIN update acme/pack --yes
  [ "$status" -eq 0 ]
  grep -q "already up to date" <<<"$output"
  [ "$(cat "$TEST_SKILL_DIR/db/plugin-sources")" = "$before" ]
}

@test "update: a new commit needs confirmation first, and the old one keeps running until then" {
  mk_repo acme pack >/dev/null
  old="$(head_of acme pack)"
  PLUGIN install acme/pack --yes >/dev/null
  bump_repo acme pack
  new="$(head_of acme pack)"
  run PLUGIN update acme/pack
  [ "$status" -eq 3 ]
  grep -q "from $old" <<<"$output"
  grep -q "to $new" <<<"$output"
  grep -q "M ext-tools/tq/handle" <<<"$output"
  [ "$(cut -f3 "$TEST_SKILL_DIR/db/plugin-sources")" = "$old" ]
  [ -d "$TEST_SKILL_DIR/plugins/sources/github/acme/pack/$old" ]
  [ ! -e "$TEST_SKILL_DIR/plugins/sources/github/acme/pack/$new" ]
}

@test "update --yes moves record and trust to the new commit and deletes the old directory" {
  mk_repo acme pack >/dev/null
  old="$(head_of acme pack)"
  PLUGIN install acme/pack --yes >/dev/null
  bump_repo acme pack
  new="$(head_of acme pack)"
  run PLUGIN update acme/pack --yes
  [ "$status" -eq 0 ]
  base="$TEST_SKILL_DIR/plugins/sources/github/acme/pack"
  [ ! -e "$base/$old" ]
  [ -d "$base/$new" ]
  [ "$(cut -f3 "$TEST_SKILL_DIR/db/plugin-sources")" = "$new" ]
  [ "$(wc -l < "$TEST_SKILL_DIR/db/plugin-sources" | tr -d ' ')" -eq 1 ]
  grep -qxF "$(printf 'ext-tools/tq\t%s' "$base/$new/ext-tools/tq")" "$TEST_SKILL_DIR/db/trusted-plugins"
  run grep -F "$base/$old" "$TEST_SKILL_DIR/db/trusted-plugins"
  [ "$status" -ne 0 ]
  run bash -c "source '$SCRIPTS/lib/driver-registry.sh'; agmsg_ext_tool_dir tq"
  [ "$output" = "$base/$new/ext-tools/tq" ]
}

@test "update of a source that is not installed is refused" {
  mk_repo acme pack >/dev/null
  run PLUGIN update acme/pack --yes
  [ "$status" -eq 1 ]
  grep -q "not installed" <<<"$output"
}

@test "remove untrusts, deletes the checkout and drops the record; the registry stops seeing it" {
  mk_repo acme pack >/dev/null
  PLUGIN install acme/pack --yes >/dev/null
  run PLUGIN remove acme/pack
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_SKILL_DIR/plugins/sources/github/acme/pack" ]
  [ ! -s "$TEST_SKILL_DIR/db/plugin-sources" ]
  [ ! -s "$TEST_SKILL_DIR/db/trusted-plugins" ]
  run bash -c "source '$SCRIPTS/lib/driver-registry.sh'; agmsg_ext_tool_dir tq"
  [ "$status" -ne 0 ]
}

@test "remove leaves another source and unrelated trust alone" {
  mk_repo acme pack >/dev/null
  mk_repo other pack2 >/dev/null
  w="$BATS_TEST_TMPDIR/work-other-pack2"
  git -C "$w" rm -rq types ext-tools
  mkdir -p "$w/types/gx"; printf 'name=gx\ntemplate=template.md\nhooks_file=.x/g.json\n' > "$w/types/gx/type.conf"
  git -C "$w" add -A; git -C "$w" commit -qm gx
  git -C "$w" push -q "$GIT_BASE/other/pack2.git" HEAD:main 2>/dev/null || git -C "$w" push -q "$GIT_BASE/other/pack2.git" HEAD
  PLUGIN install acme/pack --yes >/dev/null
  PLUGIN install other/pack2 --yes >/dev/null
  printf 'types/mine\t/somewhere/else\n' >> "$TEST_SKILL_DIR/db/trusted-plugins"
  run PLUGIN remove acme/pack
  [ "$status" -eq 0 ]
  [ "$(cut -f1 "$TEST_SKILL_DIR/db/plugin-sources")" = "github/other/pack2" ]
  grep -q "^types/gx	" "$TEST_SKILL_DIR/db/trusted-plugins"
  grep -q "^types/mine	/somewhere/else$" "$TEST_SKILL_DIR/db/trusted-plugins"
  [ -d "$TEST_SKILL_DIR/plugins/sources/github/other/pack2" ]
}

@test "install.sh-style hand-dropped plugins are untouched by install and remove" {
  mk_repo acme pack >/dev/null
  mkdir -p "$TEST_SKILL_DIR/plugins/types/hand"
  printf 'name=hand\n' > "$TEST_SKILL_DIR/plugins/types/hand/type.conf"
  PLUGIN install acme/pack --yes >/dev/null
  PLUGIN remove acme/pack >/dev/null
  [ -f "$TEST_SKILL_DIR/plugins/types/hand/type.conf" ]
}

@test "install asks y/N on a TTY and installs only on yes" {
  command -v script >/dev/null 2>&1 || skip "script(1) not available"
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) skip "no pty on this platform" ;; esac
  mk_repo acme pack >/dev/null
  # The answer is sent after a delay: the pty must be reading before it arrives.
  tty_run() {  # answer, then the command
    local ans="$1"; shift
    if script -q /dev/null true >/dev/null 2>&1; then
      { sleep 2; printf '%s\n' "$ans"; sleep 2; } | script -q /dev/null "$@"
    else
      { sleep 2; printf '%s\n' "$ans"; sleep 2; } | script -qc "$*" /dev/null
    fi
  }
  run tty_run n bash "$SCRIPTS/plugin.sh" install acme/pack
  grep -q "Cancelled" <<<"$output"
  [ ! -e "$TEST_SKILL_DIR/db/plugin-sources" ]
  run tty_run y bash "$SCRIPTS/plugin.sh" install acme/pack
  grep -q "Installed github/acme/pack" <<<"$output"
  [ -s "$TEST_SKILL_DIR/db/plugin-sources" ]
}

@test "plugin list does not show plugins/sources as an axis even with .staging present" {
  mk_repo acme pack >/dev/null
  PLUGIN install acme/pack --yes >/dev/null
  mkdir -p "$TEST_SKILL_DIR/plugins/sources/.staging/fetch.x/src/types/zz"
  run PLUGIN list
  refute grep -q "zz" <<<"$output"
  refute grep -q "^sources" <<<"$output"
}

@test "only agmsg-plugin.conf and the driver directories are kept on disk" {
  w="$(mk_repo acme pack)"
  echo readme > "$w/README.md"
  mkdir -p "$w/storage/x"; echo y > "$w/storage/x/file"
  git -C "$w" add -A; git -C "$w" commit -qm extra
  git -C "$w" push -q "$GIT_BASE/acme/pack.git" HEAD:main 2>/dev/null || git -C "$w" push -q "$GIT_BASE/acme/pack.git" HEAD
  run PLUGIN install acme/pack --yes
  [ "$status" -eq 0 ]
  d="$TEST_SKILL_DIR/plugins/sources/github/acme/pack/$(head_of acme pack)"
  [ -f "$d/agmsg-plugin.conf" ]
  [ -d "$d/types/fx" ]
  [ ! -e "$d/docs" ]
  [ ! -e "$d/storage" ]
  [ ! -e "$d/README.md" ]
  # nothing unactivated shows up as an untrusted driver
  run PLUGIN list
  refute grep -q "UNTRUSTED" <<<"$output"
}

@test "a symlink inside a driver directory is refused" {
  w="$(mk_repo acme pack)"
  ln -s /etc/hosts "$w/types/fx/link"
  git -C "$w" add -A; git -C "$w" commit -qm link
  git -C "$w" push -q "$GIT_BASE/acme/pack.git" HEAD:main 2>/dev/null || git -C "$w" push -q "$GIT_BASE/acme/pack.git" HEAD
  run PLUGIN install acme/pack --yes
  [ "$status" -eq 1 ]
  grep -q "may not contain symlinks" <<<"$output"
  [ ! -e "$TEST_SKILL_DIR/db/plugin-sources" ]
}

@test "update that adds a built-in clash prints a runnable update command that keeps the ref" {
  mk_repo acme pack >/dev/null
  PLUGIN install acme/pack@main --yes >/dev/null
  w="$BATS_TEST_TMPDIR/work-acme-pack"
  mkdir -p "$w/types/core"
  printf 'name=core\ntemplate=template.md\nhooks_file=.x/c.json\n' > "$w/types/core/type.conf"
  git -C "$w" add -A; git -C "$w" commit -qm core
  git -C "$w" push -q "$GIT_BASE/acme/pack.git" HEAD:main 2>/dev/null || git -C "$w" push -q "$GIT_BASE/acme/pack.git" HEAD
  mkdir -p "$SCRIPTS/drivers/types/core"
  printf 'name=core\n' > "$SCRIPTS/drivers/types/core/type.conf"
  run PLUGIN update acme/pack --yes
  [ "$status" -eq 1 ]
  grep -q "would replace built-in" <<<"$output"
  grep -q "agmsg plugin update acme/pack@main --override" <<<"$output"
  refute grep -q "plugin install acme/pack" <<<"$output"
  # the old commit is untouched
  [ "$(cut -f3 "$TEST_SKILL_DIR/db/plugin-sources")" != "$(head_of acme pack)" ]
  run PLUGIN update acme/pack --yes --override
  [ "$status" -eq 0 ]
}

@test "concurrent removes of different sources do not resurrect or lose rows" {
  for i in 1 2 3 4 5 6; do
    w="$(mk_repo "o$i" "p$i")"
    git -C "$w" mv types/fx "types/fx$i"; git -C "$w" mv ext-tools/tq "ext-tools/tq$i"
    git -C "$w" commit -qam "rename $i"
    git -C "$w" push -q "$GIT_BASE/o$i/p$i.git" HEAD:main 2>/dev/null || git -C "$w" push -q "$GIT_BASE/o$i/p$i.git" HEAD
    PLUGIN install "o$i/p$i" --yes >/dev/null
  done
  [ "$(wc -l < "$TEST_SKILL_DIR/db/plugin-sources" | tr -d ' ')" -eq 6 ]
  pids=""
  for i in 1 2 3 4 5 6; do
    PLUGIN remove "o$i/p$i" >/dev/null 2>&1 &
    pids="$pids $!"
  done
  for p in $pids; do wait "$p"; done
  [ ! -s "$TEST_SKILL_DIR/db/plugin-sources" ]
  [ ! -s "$TEST_SKILL_DIR/db/trusted-plugins" ]
  [ ! -d "$TEST_SKILL_DIR/plugins/sources/github" ] || [ -z "$(ls -A "$TEST_SKILL_DIR/plugins/sources/github")" ]
}

@test "concurrent installs of different sources keep every row and every trust line" {
  for i in 1 2 3 4 5 6; do
    w="$(mk_repo "o$i" "p$i")"
    git -C "$w" mv types/fx "types/fx$i"; git -C "$w" mv ext-tools/tq "ext-tools/tq$i"
    git -C "$w" commit -qam "rename $i"
    git -C "$w" push -q "$GIT_BASE/o$i/p$i.git" HEAD:main 2>/dev/null || git -C "$w" push -q "$GIT_BASE/o$i/p$i.git" HEAD
  done
  pids=""
  for i in 1 2 3 4 5 6; do
    PLUGIN install "o$i/p$i" --yes >/dev/null 2>&1 &
    pids="$pids $!"
  done
  for p in $pids; do wait "$p"; done
  [ "$(wc -l < "$TEST_SKILL_DIR/db/plugin-sources" | tr -d ' ')" -eq 6 ]
  [ "$(wc -l < "$TEST_SKILL_DIR/db/trusted-plugins" | tr -d ' ')" -eq 12 ]
}
