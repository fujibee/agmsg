def logical_events:
  .[]
  | if .type == "sync_pull_commit" then
      .messages[]? | select(.status == "imported") | .local_event // empty
    else . end;

reduce logical_events as $event (
  {sent: 0, addressed: [], read: {}};
  if $event.type == "message_sent" then
    .sent += 1
    | if $event.team == $team and $event.to == $agent then
        .addressed += [{position: .sent, id: $event.id}]
      else . end
  elif $event.type == "message_read"
       and $event.team == $team
       and $event.agent == $agent then
    .read[$event.msg_id] = true
  else . end
)
| . as $state
| ([
    $state.addressed[]
    | select(
        .position > $current
        and .position <= $target
        and (($state.read[.id] // false) | not)
      )
    | .position
  ] | min) as $gap
| if $gap == null then $target else ($gap - 1) end
