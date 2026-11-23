# Developer task entrypoint. Business logic lives in scripts/dev.py and the
# build system, never in these recipes.
_default:
    @just --list

setup:
    @python3 scripts/dev.py setup

doctor:
    @python3 scripts/dev.py doctor

build:
    @python3 scripts/dev.py build

run *args:
    @python3 scripts/dev.py run {{args}}

# `just test` = everything (the pre-commit gate). Narrow it while iterating:
#   just test cargo | viewer | browser | cache | state | settings | editor | qml
test *args:
    @python3 scripts/dev.py test {{args}}

logs:
    @python3 scripts/dev.py logs

install:
    @python3 scripts/dev.py install

# Development install: reuses the existing `build/dev/bin/kogaview` binary (only
# building `dev` when missing) behind a `KOGAVIEW_PROFILE=prod` wrapper so it
# shares the installed app ID, config directory and desktop entry without a
# second Release/RelWithDebInfo build.
install-dev:
    @python3 scripts/dev.py install-dev

uninstall:
    @python3 scripts/dev.py uninstall

package:
    @python3 scripts/dev.py package

flatpak-build:
    @python3 scripts/dev.py flatpak-build

flatpak-run:
    @python3 scripts/dev.py flatpak-run
