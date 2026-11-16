---
description: Launch the freshly built dev app in an isolated session and report boot evidence
agent: build
---
Before launching, confirm `just build` succeeded in this session — a stale binary
is not evidence.

1. `pgrep -a kogaview` and kill any stale dev instance; otherwise the new window
   reports `window is not exposed` and the run is wasted.
2. Launch isolated so the owner's real session is untouched:

   ```sh
   XDG_STATE_HOME=/tmp/opencode/kv/s XDG_CONFIG_HOME=/tmp/opencode/kv/c \
   XDG_CACHE_HOME=/tmp/opencode/kv/k QT_ASSUME_STDERR_HAS_CONSOLE=1 \
   ./build/dev/bin/kogaview $ARGUMENTS
   ```

3. Report: the boot id, `kogaview::scan` lines, any QML warning on stderr, and
   the identity it resolved (dev vs native install).
4. If the argument asks for a scenario, drive it through the `KOGAVIEW_DEV_*`
   harness and say that the input was synthetic — see the
   `real-window-verification` skill and its `references/dev-harness.md`.