---
description: Launch the freshly built dev app and report boot evidence
agent: build
---
Before launching, confirm `just build` succeeded in this session — a stale binary
is not evidence.

1. `pgrep -a kogaview` and kill any stale dev instance; otherwise the new window
   reports `window is not exposed` and the run is wasted.
2. Launch using the dev build's own identity (`kogaview-dev`, separate from prod):

   ```sh
   QT_ASSUME_STDERR_HAS_CONSOLE=1 ./build/dev/bin/kogaview $ARGUMENTS
   ```

   Only add `XDG_STATE_HOME=/tmp/opencode/kv/s XDG_CONFIG_HOME=/tmp/opencode/kv/c XDG_CACHE_HOME=/tmp/opencode/kv/k` when testing clean-start, locale/settings resets, or when a clean single-run journal is needed.

3. Report: the boot id, `kogaview::scan` lines, any QML warning on stderr, and
   the identity it resolved (dev vs native install).
4. If the argument asks for a scenario, drive it through the `KOGAVIEW_DEV_*`
   harness and say that the input was synthetic — see the
   `real-window-verification` skill and its `references/dev-harness.md`.