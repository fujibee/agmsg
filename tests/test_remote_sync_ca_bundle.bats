#!/usr/bin/env bats
# remote-sync.sh bridges CURL_CA_BUNDLE into NODE_EXTRA_CA_CERTS so a private
# CA trusted by remote.sh's curl calls (connect) is also trusted by the Node
# processes remote-sync.sh execs into (the persistent sync engine, and
# pull's resolve-team lookup). See #744.

load test_helper

setup() {
  setup_test_env
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"

  # A stub "node" that prints NODE_EXTRA_CA_CERTS and exits, instead of
  # running the real engine. AGMSG_NODE (checked before PATH lookup in
  # lib/node.sh) points remote-sync.sh at it.
  STUB_NODE="$BATS_TEST_TMPDIR/stub-node"
  cat > "$STUB_NODE" <<'STUB'
#!/usr/bin/env bash
printf 'NODE_EXTRA_CA_CERTS=%s\n' "${NODE_EXTRA_CA_CERTS-<unset>}"
STUB
  chmod +x "$STUB_NODE"
  export AGMSG_NODE="$STUB_NODE"
}

teardown() { teardown_test_env; }

@test "CURL_CA_BUNDLE is bridged to NODE_EXTRA_CA_CERTS when Node's own var is unset" {
  export CURL_CA_BUNDLE="/tmp/my-ca.pem"
  unset NODE_EXTRA_CA_CERTS
  run bash "$SCRIPTS/remote-sync.sh" status
  [ "$status" -eq 0 ]
  [ "$output" = "NODE_EXTRA_CA_CERTS=/tmp/my-ca.pem" ]
}

@test "an explicit NODE_EXTRA_CA_CERTS is left untouched even when CURL_CA_BUNDLE is set" {
  export CURL_CA_BUNDLE="/tmp/my-ca.pem"
  export NODE_EXTRA_CA_CERTS="/tmp/a-different-ca.pem"
  run bash "$SCRIPTS/remote-sync.sh" status
  [ "$status" -eq 0 ]
  [ "$output" = "NODE_EXTRA_CA_CERTS=/tmp/a-different-ca.pem" ]
}

@test "NODE_EXTRA_CA_CERTS stays unset when neither variable is provided" {
  unset CURL_CA_BUNDLE
  unset NODE_EXTRA_CA_CERTS
  run bash "$SCRIPTS/remote-sync.sh" status
  [ "$status" -eq 0 ]
  [ "$output" = "NODE_EXTRA_CA_CERTS=<unset>" ]
}

@test "an explicitly empty NODE_EXTRA_CA_CERTS counts as set and is left untouched" {
  export CURL_CA_BUNDLE="/tmp/my-ca.pem"
  export NODE_EXTRA_CA_CERTS=""
  run bash "$SCRIPTS/remote-sync.sh" status
  [ "$status" -eq 0 ]
  [ "$output" = "NODE_EXTRA_CA_CERTS=" ]
}
