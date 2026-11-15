# Linux desktop assets

The desktop entry is a TEMPLATE only. The app ID `io.github.tienv2i.KogaView` is
provisional (see `docs/adr/0001-project-identity-and-naming.md`); confirm
namespace ownership before shipping. Generate production and dev variants with
distinct identities, provide icon assets and AppStream metadata, and verify the
MIME list against actually supported codecs before packaging. Never set the
default image viewer without user consent.
