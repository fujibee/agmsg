<!-- Devin overlay. -->
<!-- agmsg:slot delivery -->
<!-- agmsg:render-overlay __AGENT_TYPE__ -->
**Sending a message:** pass the body on stdin with `--stdin`. It reads it verbatim from a file descriptor, so nothing you write is re-parsed by a shell or capped by an argv limit. The older positional form — `send.sh <team> <from> <to> "<message>"` — is **deprecated** (#378): your shell parses that message before agmsg ever sees it, so backticks or `$(...)` in the body can be evaluated there, and on Windows a long body is silently truncated at 8186 bytes. **A message you compose MUST NOT use the positional form.** If the body is literally `--`, `--stdin`, or `--force`, put `--` in front of it: `send.sh <team> <from> <to> -- --stdin` — and for a body of `--`, that is `-- --`. Pick a heredoc delimiter the body cannot contain on a line by itself — a body with a bare `AGMSG_BODY` line would end the heredoc early and the rest would run as shell commands.
  5. Devin has no agmsg automatic delivery hook. Keep delivery `off` and check `__CMD_PREFIX____SKILL_NAME__` manually.
<!-- /agmsg:slot delivery -->
<!-- agmsg:slot execute-extra -->
Devin is not spawnable: an interactive boot mode that can be pre-seeded with agmsg's initial `actas` prompt has not yet been verified, so `spawn` is refused rather than pretending to start a seat. This is unrelated to Hermes's own spawn limitation (#279) and may be revisited separately.
<!-- /agmsg:slot execute-extra -->
<!-- agmsg:slot mode -->
If argument is "mode", run `delivery.sh status __AGENT_TYPE__ "$(pwd)"`.
Only `off` is supported for Devin; reject `monitor`, `turn`, and `both`.
<!-- /agmsg:slot mode -->
