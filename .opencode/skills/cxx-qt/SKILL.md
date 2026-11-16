---
name: cxx-qt
description: Use when working on the CXX-Qt bridge (crates/desktop/src/bridge.rs), the generated bridge.cxxqt.h, the cxx-qt-build and CMake wiring, or the QML that instantiates KogaViewBridge. Records the 0.10 API this project relies on, the adapter invariants, and the build traps that have already cost time.
---

# CXX-Qt 0.10 in KogaView

Version facts — re-check with `cargo tree -i cxx-qt` before upgrading anything:

- `cxx-qt`, `cxx-qt-build`, `cxx-qt-lib` **0.10** (locked 0.10.0; CMake fetches CxxQt
  by `GIT_TAG 0.10.0`), Qt **6.5+** (the dev session runs 6.12), C++17.
- One bridge crate: `kogaview_desktop`, `crate-type = ["staticlib"]`, linked into
  the C++ executable.
- Attributes that exist in 0.10: `qobject`, `qml_element`, `qml_singleton`,
  `qproperty`, `qinvokable`, `qsignal`, `qenum`, `inherit`, `base`, `cxx_name`,
  `rust_name`, `doc`, `namespace`. There is no `qml_name`/`qml_attached` in this
  version — do not invent attributes.
- This file is meant to *replace* a lookup, not add one. Only if it does not
  answer the question: the crate source
  (`~/.cargo/registry/src/*/cxx-qt-0.10.0`, where `cxx-qt-gen-0.10.0/test_inputs/`
  holds the smallest valid example of every attribute) or the book
  <https://kdab.github.io/cxx-qt/book/>. Read only the gap, then record the
  answer here so the next session does not pay for it again.
- If `cargo tree -i cxx-qt` reports anything but 0.10.x, these facts are stale:
  trust the crate, and correct this file in the same change.

## Where the pieces live

| Piece | Location |
|---|---|
| Bridge | `crates/desktop/src/bridge.rs` — the only `#[cxx_qt::bridge]` |
| Generated header | `#include <kogaview_desktop/src/bridge.cxxqt.h>` (in `cpp/main.cpp`) |
| Rust build | `crates/desktop/build.rs` — `CxxQtBuilder::new_qml_module(...)` |
| CMake | `CMakeLists.txt` — `cxx_qt_import_crate`, `cxx_qt_import_qml_module` |
| QML type | `import io.github.tienv2i.KogaView 1.0`, `KogaViewBridge { id: bridge }` (`Main.qml:57`) |
| Rust free functions called from C++ | `kogaview_initialize`, `kogaview_shutdown`, `kogaview_app_id`, `kogaview_cache_dir`, … |

The bridge object is created **by QML**, not by C++. C++ reaches it through
`objectName: "bridge"` (that is how the QA harness dispatches commands).

## Shape of the bridge

One `#[cxx_qt::bridge] pub mod qobject`, three blocks:

1. `unsafe extern "C++"` — only `QString` from `cxx-qt-lib/qstring.h`.
2. `extern "Rust"` — free functions C++ calls before the QML engine exists.
3. `extern "RustQt"` — the `#[qobject] #[qml_element]` type, its `#[qproperty]`
   list and its `#[qinvokable]` methods.

Naming rules that are not optional:

- Rust struct `KogaViewBridgeRust`, QML/C++ type `KogaViewBridge`
  (`type KogaViewBridge = super::KogaViewBridgeRust;`).
- A `#[qproperty(T, name)]` field name **is** the `Q_PROPERTY` name; nothing
  converts snake_case. That is why the fields are camelCase and
  `crates/desktop/src/lib.rs` carries `#![allow(non_snake_case)]`.
- Keep an explicit `#[cxx_name]` on invokables so the C++/QML name stays
  greppable and does not silently follow a Rust rename.
- Only `QString`, `u32`, `u64`, `bool` cross the boundary. No `Vec`, no
  `HashMap`, no `QVariant`: the adapter serialises JSON (`stateJson`,
  `listingJson`) and QML parses it once.
- Invokables that mutate take `self: Pin<&mut Self>`; read-only ones may take
  `&self`.

## Adapter invariants (project rules, not CXX-Qt's)

- `dispatch`, `query`, `poll` are the only entry points. QML serialises an
  `Envelope`; it never mutates domain state.
- **A property reaches QML only through its generated setter.**
  `set_listingJson(...)` emits `listingJsonChanged`; assigning to
  `this.listingJson` inside Rust updates the struct and nothing else — the
  window keeps the old value, with no error.
- Re-borrow after every `rust_mut()`; compute first, then set:

```rust
let (epoch, state) = {
    let this = self.as_mut().rust_mut().get_mut();
    (this.core.listing_epoch(), this.core.meta_json())
};
self.as_mut().set_listingEpoch(epoch);
self.as_mut().set_stateJson(state.into());
```

  Holding `this` across a `self.as_mut()` call does not compile — that is why
  `refresh_properties` collects into a tuple first.
- Gate the expensive property. `listingJson` is re-serialised only when
  `listingEpoch` moves, and `StateSnapshot.qml` applies it only when the epoch
  changed; a thousand photos is ~200 KB per republish.
- No panic in an invokable: a panic must not cross the FFI boundary. Return the
  failure inside the JSON result (the gateway already does) and never `unwrap()`
  on input.
- No domain logic here. A rule belongs in Core with a protocol test; the bridge
  only adapts.

## Threading

- The object lives on the GUI thread and must not be moved off it. Core runs its
  own workers; **`poll()` is pulled by a 120 ms QML `Timer`** (`Main.qml`), which
  returns `true` when state moved.
- Do not hold a Rust borrow across anything that can re-enter the bridge.
- Do not reach for `CxxQtThread` or a queued invocation until you have shown
  that `poll()` cannot serve the case: the pull model is what keeps one
  authoritative state owner.

## Adding or changing something

1. **New property** — `#[qproperty(T, name)]` + field + `Default` value + set it
   in `refresh_properties`, then grep the readers in `crates/desktop/qml/` and
   `tests/qml/`. A QML binding to a missing property is a runtime warning only.
2. **New invokable** — `#[qinvokable] #[cxx_name = "…"]` plus the method in
   `impl qobject::KogaViewBridge`.
3. **New QML file** — list it in `qml_files([...])` in `build.rs`. A stale entry
   there fails the build; a missing entry means the file never reaches the
   module.
4. **New Qt module** — declare it in `build.rs` (`.qt_module(...)`) **and** in
   `CMakeLists.txt` (`QT_MODULES`). One without the other fails the link and
   names neither file.
5. **New command triggered from QML** — protocol test plus a journal assertion. A
   property change alone does not prove the command reached the gateway.

## Build and generated code

- `cxx-qt-build` generates the header and the QML module during `cargo build`;
  `just build` drives both halves. Editing `bridge.rs`/`build.rs` without
  rebuilding leaves C++ compiled against the old header — the symptom is a
  missing property or `Type KogaViewBridge unavailable` at **runtime**, not a
  compile error.
- `just test` runs the Qt Quick suites against the real `.qml` sources, but those
  test binaries do not link the Rust staticlib, so they cannot instantiate
  `KogaViewBridge`. `Main.qml` is therefore not loadable there; `tst_browser`
  drives `BrowserView.qml` with a stub. A bridge change needs the real window.
- Renaming the `objectName` silently breaks the QA harness, which finds the
  bridge by name.

## Traps already hit

- Forgetting `self.as_mut()` before a setter after `rust_mut()` — the usual
  borrow-checker error.
- `u64` arrives in QML as a JS number (double). `revision`/`listingEpoch` are
  fine at these magnitudes; do not put timestamps or byte counts in `u64`
  properties.
- QML *can* write a `#[qproperty]`, and nothing stops a `bridge.stateJson = …` in
  a handler. That desynchronises the snapshot from Core; treat every property as
  read-only from QML.
- `QString` ↔ `String` conversions live at the boundary: `.to_string()` on the
  way in, `.into()` on the way out, `&QString` for borrowed parameters.
- A `#[qsignal]` is only needed when C++ must observe something QML cannot poll.
  Nothing in this bridge uses one; the first one is a design change worth an ADR.

## Constructs not used yet (shapes verified against 0.10)

Nothing below exists in `bridge.rs` today; copy the shape when you need it
instead of opening the book.

```rust
// Q_ENUM on the object. Declared in the bridge module, not in an extern block.
// QML reaches the values through the type (`KogaViewBridge.Name`); the Rust
// enum name is not itself a QML type.
#[qenum(KogaViewBridge)]
enum SortMode { Name, Modified }

// A Qt signal: empty body, CXX-Qt-compatible arguments. Only for a C++ observer —
// QML already reacts to every #[qproperty] change signal.
#[qsignal]
fn listingRefreshed(self: Pin<&mut KogaViewBridge>);

// One instance per engine, no `id:` in QML.
#[qobject]
#[qml_element]
#[qml_singleton]
type KogaViewPrefs = super::KogaViewPrefsRust;
```

`#[qenum]` without a type argument (plus `qnamespace!(...)`) registers a
namespaced enum instead of a `Q_ENUM` on the object. `#[inherit(QObject)]` /
`#[base]` exist in 0.10 but this bridge inherits nothing, and adding an
inheritance level is a design change worth an ADR.

## Verify a bridge change

1. `just build` (mandatory), then `just test`.
2. Launch the real window and watch stderr for QML warnings and
   `Type … is not a type`.
3. Send one command, then confirm in this order: the journal line (`ok:true`, a
   bumped `revision`), then the rendered value on screen. The journal alone does
   not prove QML saw it.