#!/usr/bin/env bats

# `npx agmsg addon init|check`: authoring tools for app add-ons. They work on
# the current directory only, and `check` must refuse what the app's installer
# refuses, with the same reasons.

BIN="$BATS_TEST_DIRNAME/../bin/agmsg.js"

setup() {
  cd "$BATS_TEST_TMPDIR"
  git init -q proj
  cd proj
  git config user.email t@example.com
  git config user.name t
}

scaffold() {
  node "$BIN" addon init demo >/dev/null
  sed -i.bak 's/^why.messages:read = $/why.messages:read = Shows the timeline./' app-panes/demo/addon.conf
  rm app-panes/demo/addon.conf.bak
  mkdir -p dist/assets
  printf '<!doctype html><script type="module" src="./assets/a.js"></script>\n' > dist/index.html
  printf 'console.log(1)\n' > dist/assets/a.js
  node scripts/agmsg-addon-copy.mjs dist demo >/dev/null
  git add -A
  git commit -qm scaffold
}

@test "addon init: writes the layout and never overwrites" {
  run node "$BIN" addon init demo
  [ "$status" -eq 0 ]
  [ -f agmsg-plugin.conf ]
  [ -f app-panes/demo/addon.conf ]
  [ -f agmsg-addon.js ]
  [ -f scripts/agmsg-addon-copy.mjs ]
  echo keep > agmsg-plugin.conf
  run node "$BIN" addon init demo
  [[ "$output" =~ "skip   agmsg-plugin.conf (exists)" ]]
  [ "$(cat agmsg-plugin.conf)" = keep ]
}

@test "addon init: rejects a bad name" {
  run node "$BIN" addon init Bad_Name
  [ "$status" -eq 2 ]
  [ ! -d app-panes ]
}

@test "addon check: a committed scaffold passes" {
  scaffold
  run node "$BIN" addon check
  [ "$status" -eq 0 ]
  [[ "$output" =~ "ok: the app would accept this layout." ]]
}

@test "addon check: no app-panes is refused with the install message" {
  run node "$BIN" addon check
  [ "$status" -eq 1 ]
  [[ "$output" =~ "No app add-on here (no app-panes/ folder)" ]]
}

@test "addon check: an unknown permission is refused, not ignored" {
  scaffold
  sed -i.bak 's/^permissions = messages:read$/permissions = messages:read, files:write/' app-panes/demo/addon.conf
  run node "$BIN" addon check
  [ "$status" -eq 1 ]
  [[ "$output" =~ 'unknown permission "files:write"' ]]
}

@test "addon check: a symbolic link is refused" {
  scaffold
  ln -s /etc/hosts app-panes/demo/web/hosts
  git add -A
  git commit -qm link
  run node "$BIN" addon check
  [ "$status" -eq 1 ]
  [[ "$output" =~ "symbolic link at app-panes/demo/web/hosts" ]]
}

@test "addon check: an uncommitted web/ is refused" {
  node "$BIN" addon init demo >/dev/null
  mkdir -p dist
  printf '<!doctype html>\n' > dist/index.html
  node scripts/agmsg-addon-copy.mjs dist demo >/dev/null
  run node "$BIN" addon check
  [ "$status" -eq 1 ]
  [[ "$output" =~ "index.html is not committed" ]]
}

@test "addon check: inline handlers install but are reported as blocked" {
  scaffold
  printf '<!doctype html><button onclick="go()">x</button>\n' > app-panes/demo/web/index.html
  git commit -qam handler
  run node "$BIN" addon check
  [ "$status" -eq 1 ]
  [[ "$output" =~ "blocked: app-panes/demo/web/index.html: inline event handlers" ]]
  [[ "$output" =~ "The app would install this, but 1 thing(s) will be blocked" ]]
}

@test "addon check: network needs an origin list" {
  scaffold
  sed -i.bak 's/^permissions = messages:read$/permissions = messages:read, network/' app-panes/demo/addon.conf
  run node "$BIN" addon check
  [ "$status" -eq 1 ]
  [[ "$output" =~ 'network is declared but "network = *" or a list of origins is missing' ]]
}
