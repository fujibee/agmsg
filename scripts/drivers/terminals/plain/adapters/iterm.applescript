on run argv
  set operation to item 1 of argv
  set wantedTTY to item 2 of argv
  set matches to {}

  try
    if application "iTerm2" is not running then return "unsupported: iTerm is not running"
    tell application "iTerm2"
      repeat with terminalWindow in windows
        repeat with terminalTab in tabs of terminalWindow
          repeat with terminalSession in sessions of terminalTab
            if tty of terminalSession is wantedTTY then set end of matches to terminalSession
          end repeat
        end repeat
      end repeat

      if (count of matches) is not 1 then
        if operation is "probe" then return "unsupported: iTerm tty matched " & (count of matches) & " sessions"
        error "iTerm tty no longer identifies exactly one session"
      end if
      set targetSession to item 1 of matches

      if operation is "probe" then return "supported"
      if operation is "peek" then return contents of targetSession
      if operation is "poke" then
        set bodyText to item 3 of argv
        tell targetSession
          write text bodyText newline no
          write text ""
        end tell
        return ""
      end if
      return "unsupported: unknown iTerm adapter operation"
    end tell
  on error errorText
    if operation is "probe" then return "unknown: iTerm adapter error: " & errorText
    error errorText
  end try
end run
