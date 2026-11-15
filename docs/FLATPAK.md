# Flatpak Readiness — Photo Manager & Editor

## Objective
Develop native-first, remain sandbox-compatible, package Flatpak later. This document defines design constraints, **not** a claim that a Flatpak package already exists or works.

## Identity and desktop metadata
- Choose one stable reverse-DNS application ID before publishing (placeholder: `io.github.tienv2i.KogaView`; replace with an ID you control).
- Align the ID across Flatpak manifest, `.desktop` file, AppStream metadata and installed icon names.
- Prepare MIME associations, desktop integration and localization metadata.

## Storage and file access
- Respect XDG configuration, data and cache directories; use Qt platform APIs where appropriate. Never hardcode user home paths or assume `/usr` is writable.
- Treat images outside the sandbox as untrusted and potentially permission-scoped. Use portal-compatible native file selection; support document grants and access revocation.
- Distinguish stable image IDs from filesystem paths and URIs. Revalidate access on reopen, restart and batch processing.
- Stage writes and handle failures safely; only export to explicitly permitted destinations.

## Desktop portals and display
- Prefer XDG Desktop Portals for sandboxed file chooser, opening URIs and other desktop-mediated operations where applicable. Confirm actual Qt/portal behavior on GNOME and KDE.
- Capture the application window through the Qt UI adapter where feasible; desktop-wide capture requires portal/user authorization and is not guaranteed.
- Support Wayland as a first-class target; X11 fallback only as necessary. Honor system font, palette, icon, accessibility and Qt high-DPI handling.

## IPC, CLI and MCP
- UI, CLI and MCP share the same typed Envelope/Command Bus semantics, regardless of transport.
- An internal Unix socket does **not** automatically become reachable from a host CLI outside the Flatpak sandbox. Define and test a least-privilege, explicitly authorized transport (for example, an appropriately permitted D-Bus interface or intentionally shared socket).
- Do not enable unrestricted session-bus access, broad filesystem permissions or sandbox escapes merely to make Agent access convenient.
- Enforce capability checks and user consent for destructive actions, external filesystem access and screenshots.

## Build and dependencies
- Keep Cargo and CMake/CXX-Qt integration reproducible; pin dependencies and prepare offline/vendored build inputs as required by the packaging workflow.
- Target a compatible Qt 6 Flatpak runtime/SDK and package required native dependencies. Check ABI, plugins, codecs and license obligations.
- Reserve `packaging/flatpak/` for the future manifest and metadata; do not introduce an untested manifest and call it supported.

## Future acceptance checklist
1. Build, install and launch the actual Flatpak sandboxed app on GNOME and KDE.
2. Open images using the portal file chooser, navigate, edit and export to authorized locations.
3. Restart and verify persisted metadata, access grants, thumbnails and cache behavior.
4. Validate Wayland UI scaling, theme, icons, dialogs, accessibility and screenshots.
5. Validate host CLI/MCP connectivity only if that integration is intentionally supported; verify denial paths.
6. Inspect logs, journal and actual output files; do not rely on green tests alone.
7. Review manifest permissions for least privilege and document any exceptions.

## Engineering rule
Any feature requiring broad host access must be redesigned or explicitly documented as unsupported under Flatpak. Never silently weaken sandbox isolation.
