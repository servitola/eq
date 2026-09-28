#!/bin/zsh
# Install build/EQDriver.driver on this Mac for development: sudo Driver/dev-install.sh
# Restarts coreaudiod, which drops every app's audio for about a second.
set -euo pipefail
cd "${0:a:h}"

src=build/EQDriver.driver
hal=/Library/Audio/Plug-Ins/HAL
dst=$hal/EQDriver.driver
# Beside HAL/, not in it: coreaudiod loads every *.driver it finds there.
stage=/Library/Audio/Plug-Ins/.EQDriver.driver.staging
old=/Library/Audio/Plug-Ins/.EQDriver.driver.old

(( EUID == 0 )) || { echo "run it as root: sudo $0" >&2; exit 1; }
[[ -d $src ]] || { echo "no $src; run Driver/build.sh first" >&2; exit 1; }
codesign --verify --strict "$src"

# Never overwrite the loaded binary in place; the running helper has it mapped. Stage, then rename.
/bin/rm -rf "$stage" "$old"
ditto "$src" "$stage"
chown -R root:wheel "$stage"
chmod -R go-w "$stage"
[[ -e $dst ]] && mv "$dst" "$old"
mv "$stage" "$dst"
/bin/rm -rf "$old"

killall coreaudiod
echo "installed $dst; coreaudiod restarted"
echo "check it:        Driver/build/probe"
echo "pick the target: Driver/build/probe target <device UID>"
echo "disable it:      sudo touch $dst/Contents/Resources/disabled && sudo killall coreaudiod"
echo "remove it:       sudo Driver/dev-uninstall.sh"
