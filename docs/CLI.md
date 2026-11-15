# CLI and activation specification

## Desktop executable
```
kogaview
kogaview open /path/to/photo.jpg [/path/to/other.png ...]
kogaview /path/to/photo.jpg
kogaview open-folder /path/to/Pictures
kogaview --help
kogaview --version
```
- `kogaview` owns startup and desktop activation; argument parsing must be consistent on Windows/Linux.
- `open` requires at least one file, `open-folder` exactly one directory; return nonzero with structured error for invalid input.
- Multiple files open in Viewer with a deterministic navigation set.
- A running instance receives forwarded requests through instance coordination/IPC.

## Control client (target API)
```
kogactl status
kogactl open /path/to/photo.jpg
kogactl open-folder /path/to/Pictures
kogactl workspace switch viewer
kogactl debug logs --last 200
kogactl debug trace --request-id req-001
kogactl debug state
kogactl debug screenshot
kogactl debug bundle --output report.zip
kogactl debug replay --journal report.jsonl --sandbox
```
- `kogactl` is a separate executable; commands above are design targets, not currently implemented.
- Shared typed Envelope, response semantics, error codes, authorization and revision checks with UI/MCP.
- `accepted` with `task_id` differs from `completed`; progress and cancellation are observable.
- For Flatpak, external CLI connectivity needs a separately designed, permission-aware transport. Do not assume sandbox-private socket is accessible.
