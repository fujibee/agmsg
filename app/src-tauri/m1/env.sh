# Shared by the m1/*.sh scripts. Sourced, not run.
#   M1_RUN       log directory (default /tmp/m1run)
#   M1_PREBUILT  directory holding agmsg-app-<variant>-<profile>[.exe] built by CI; when set, nothing is built
RUN=${M1_RUN:-/tmp/m1run}
mkdir -p "$RUN"
# Native Windows programs need C:/... style paths; elsewhere this is a no-op.
nat() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
RUN_N=$(nat "$RUN")
# prebuilt_exe <variant> <profile>: prints the executable to launch, or fails
prebuilt_exe() {
  local v=$1 p=$2
  [ -n "${M1_MAIN_CSP:-}" ] && v="${v}csp"
  local exe="$M1_PREBUILT/agmsg-app-$v-$p"
  if [ -f "$exe.exe" ]; then echo "$exe.exe"; elif [ -f "$exe" ]; then echo "$exe"; else echo "no prebuilt executable $exe(.exe)" >&2; return 1; fi
}
