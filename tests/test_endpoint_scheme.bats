#!/usr/bin/env bats

# Which endpoints may be spoken to over plaintext http.
#
# The rule is "IP literal in a private range", not "loopback". The strict URL
# parsing exists to stop a NAME dressed as a safe host — `127.0.0.1.evil.com`
# reads like loopback and resolves wherever its owner points it. A literal has
# no such gap: what is written is where the connection goes. So names stay
# https-only (`localhost` excepted) and a LAN address over http is allowed.
#
# One implementation decides this. Connect and pull invoke its CLI adapter;
# continued sync calls the same exported function through connectedBinding().

load test_helper

# Both checks are pure functions of the URL — no store, no team, no state — so
# they are exercised against the repository's own scripts rather than a built
# test environment. Nothing here writes anything.
setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
}

@test "endpoint: the connect/pull adapter accepts a private LAN IP over http (#717/#722)" {
  run node "$SCRIPTS/internal/validate-endpoint.mjs" "http://192.168.191.205:8787"
  [ "$status" -eq 0 ]
}

@test "endpoint: the userinfo trick is still refused (#717)" {
  # `http://localhost@evil.com` parses with host evil.com. The validator rejects
  # userinfo outright rather than relying on the host check behind it, and the
  # message says which part was the problem — neither of which a verdict column
  # can express.
  run node "$SCRIPTS/internal/validate-endpoint.mjs" "http://localhost@evil.com"
  [ "$status" -ne 0 ]
  grep -qF 'userinfo' <<<"$output"
}

@test "endpoint: the refusal says what to do instead, and says why truthfully (#717)" {
  run node "$SCRIPTS/internal/validate-endpoint.mjs" "http://example.com:8787"
  [ "$status" -ne 0 ]
  # Plain commands and `refute`, not `[[ ]]`: a non-last `[[ ]]` cannot fail a
  # test on bash 3.2, which is what CI's macOS legs run (#670, #716). Every one
  # of these is non-last, so as `[[ ]]` they would have asserted nothing there.
  #
  # The old message blamed a "token/credential" being sent unencrypted. The
  # client sends no Authorization header at all, so that was never the risk;
  # the risk is the message bodies of a team synced without encryption.
  refute grep -qF 'credential' <<<"$output"
  grep -qF 'message bodies' <<<"$output"
  # And a refusal that does not say what to do instead leaves the operator to
  # find a tunnel on their own, which is what happened.
  grep -qF 'https://' <<<"$output"
  grep -qF 'LAN IP' <<<"$output"
  grep -qF -- '--e2ee' <<<"$output"
}

@test "endpoint: the refusal names the zone, and the list names what is allowed (#717)" {
  # Two gaps found by the seat building the table, and the second is the
  # quieter one. Someone who wrote a zone index HAS given a private address —
  # answering them with "use a private IP" is a dead end, so the zone gets its
  # own message naming the part that is wrong and a form that works.
  run node "$SCRIPTS/internal/validate-endpoint.mjs" "http://[fe80::1%eth0]:8787"
  [ "$status" -ne 0 ]
  grep -qF 'zone index' <<<"$output"
  grep -qF 'fe80::1' <<<"$output"

  # And the general refusal lists fe80::/10, which is accepted. Allowing
  # something without saying so is worse than the dead end: nobody hits an
  # error, so nobody reports that link-local works.
  run node "$SCRIPTS/internal/validate-endpoint.mjs" "http://example.com:8787"
  [ "$status" -ne 0 ]
  grep -qF 'fe80::/10' <<<"$output"

  # The claim above is only worth anything if it is true.
  run node "$SCRIPTS/internal/validate-endpoint.mjs" "http://[fe80::1]:8787"
  [ "$status" -eq 0 ]
}
