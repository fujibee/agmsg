on run argv
  set operation to item 1 of argv
  set wantedTTY to item 2 of argv
  set matches to {}

  try
    if application "Terminal" is not running then return "unsupported: Terminal is not running"
    tell application "Terminal"
      repeat with terminalWindow in windows
        repeat with terminalTab in tabs of terminalWindow
          if tty of terminalTab is wantedTTY then set end of matches to terminalTab
        end repeat
      end repeat

      if (count of matches) is not 1 then
        if operation starts with "probe" then return "unsupported: Terminal tty matched " & (count of matches) & " tabs"
        error "Terminal tty no longer identifies exactly one tab"
      end if
      set targetTab to item 1 of matches

      if operation is "probe" then return "unknown: Terminal.app write-submit has not been measured (only iTerm has)"
      if operation is "probe_despawn" then return "supported"
      if operation is "peek" then return history of targetTab
      if operation is "poke" then
        do script (item 3 of argv) in targetTab
        return ""
      end if
      if operation is "despawn" then
        close targetTab
        return ""
      end if
      return "unsupported: unknown Terminal adapter operation"
    end tell
  on error errorText
    if operation starts with "probe" then return "unknown: Terminal adapter error: " & errorText
    error errorText
  end try
end run
