---
description: Read the newest structured log and the command journal, then triage
agent: build
---
Two different files, never confuse them:

- **Structured log** — `$XDG_STATE_HOME/kogaview[-dev]/logs/kogaview.jsonl.<YYYY-MM-DD>`
  (`just logs` prints the newest). Daily-rolled, so the name carries a date.
  Fields include `state_dir`, `log_dir` and `boot_id`.
- **Command journal** — `$XDG_STATE_HOME/kogaview[-dev]/journal/commands.jsonl`.
  One line per command that reached the gateway: `id`, `command`, `ok`,
  `revision`, sanitized `paths`, and `message`/`error`. A rejected command is
  there too, with `ok:false` and the revision it did not bump.

Triage in this order: log (boot id, `kogaview::scan`, `kogaview::command`) →
journal (ids, order, revisions) → AppState revision.

Report the boot id of the run you are reading, the rejected commands with their
error code, and the last revisions. Then state the conclusion:

- command ran, revision bumped, UI did not move → render path (QML or the adapter
  that publishes state);
- command rejected → read the `kogaview::command` line, re-run with
  `RUST_LOG=kogaview_core=debug` if the default filter hides it;
- nothing in the journal → the action never produced a command: a dead handler or
  a QML error. That is a QML/bridge bug found by reading the QML.