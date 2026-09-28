#!/bin/zsh
# Remove the development install: sudo Driver/dev-uninstall.sh
set -euo pipefail

dst=/Library/Audio/Plug-Ins/HAL/EQDriver.driver
(( EUID == 0 )) || { echo "run it as root: sudo $0" >&2; exit 1; }
[[ -e $dst ]] || { echo "$dst is not installed"; exit 0; }
/bin/rm -rf "$dst"
killall coreaudiod
echo "removed $dst; coreaudiod restarted"
