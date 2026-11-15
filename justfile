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
#   just test cargo | viewer | browser | cache | qml
test *args:
    @python3 scripts/dev.py test {{args}}

logs:
    @python3 scripts/dev.py logs

install:
    @python3 scripts/dev.py install

uninstall:
    @python3 scripts/dev.py uninstall

package:
    @python3 scripts/dev.py package

flatpak-build:
    @python3 scripts/dev.py flatpak-build

flatpak-run:
    @python3 scripts/dev.py flatpak-run
