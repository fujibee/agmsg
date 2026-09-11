#!/usr/bin/env bash
# devin delivery plug — manual inbox checks only.
#
# Devin has no agmsg automatic delivery hook: the only valid mode is `off`
# (enforced by delivery_modes=off in the manifest, which the central gate in
# delivery.sh checks). These overrides keep apply / status / teardown from
# touching a hook file or another agent type's watchers. Sourced into
# delivery.sh's context.

# Nothing to write — manual-only, so no hooks_file is resolved or created.
agmsg_delivery_apply() { :; }

# No hook file to read; the mode is always off.
agmsg_delivery_status() { echo "mode: off"; }

# No watcher or bridge of our own. Do NOT fall through to the default teardown
# (which stops this project's watch.sh) — another agent type may hold a live
# watcher on the same project, and a devin `set off` must not disturb it.
agmsg_delivery_on_disable() {
  echo "Devin has no agmsg automatic delivery hook; manual inbox checks only."
}
