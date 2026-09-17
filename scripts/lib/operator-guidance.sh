#!/usr/bin/env bash
# Who tells the operator what to do next.
#
# These scripts are run two ways: directly, and by a larger tool that runs them
# with stdio inherited so their progress and prompts reach the same terminal.
# That inheritance is deliberate — but it also means guidance written for
# someone driving agmsg by hand lands in front of someone driving something
# else, and the route it names may not be the route they have. It can be worse
# than useless: telling an operator to carry key material out of band, when the
# tool they are using has a ceremony that exists to make that unnecessary,
# talks them out of the safer path.
#
# So the caller says whether it owns that job, and everything here asks ONE
# function rather than reading the variable itself. Two readers of one variable
# is how the two sides drift apart, and a drift here is silent: the screen just
# says something untrue.
#
# The question is "am I the one who should speak", NOT "who called me". A
# variable naming the caller (AGMSG_CALLED_BY=cloud) would make this file start
# counting kinds of caller, and grow a branch for every new one. What these
# scripts need to know has no plural.
#
# Facts are NOT guidance. "Losing this key makes its messages unreadable" is
# true however agmsg was invoked, and stays. What gets held back is only the
# next step — which route to take, which command to run.

# agmsg_operator_guidance_is_ours -> 0 when this process should print the
# "what to do next" guidance, 1 when the caller has taken that on.
#
# Unset is 0: a plain install must behave exactly as it always has, and the
# quiet mode has to be asked for explicitly. Any value other than `caller` is
# also 0 — an unrecognised setting must not silence a page of guidance.
agmsg_operator_guidance_is_ours() {
  [ "${AGMSG_OPERATOR_GUIDANCE:-}" = "caller" ] && return 1
  return 0
}
