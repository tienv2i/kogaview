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

# Development install: same app ID, data directories and desktop entry as
# `just install`, but optimized-with-hooks instead of Release. Use it to exercise
# the installed app with the `KOGAVIEW_DEV_*` evidence harness.
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
