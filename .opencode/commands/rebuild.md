---
description: Build the dev app and report the canonical artifact
agent: build
---
Run `just build`. Report the canonical binary path it prints; for a Rust change
also run `cargo fmt --check`.

If the build fails: report the first error with its file:line, fix it only if it
is inside the change being made, and rebuild. Never launch or test the previous
binary and call that a verification of the new code — say the build failed and
stop.