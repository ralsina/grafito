#!/bin/bash -x

set -e

NAME=grafito

rm -rf aur-${NAME}
git clone ssh://aur@aur.archlinux.org/${NAME}.git aur-${NAME}
sed "s/pkgver=.*/pkgver=$(shards version)/" -i aur-${NAME}/PKGBUILD
sed "s/pkgrel=.*/pkgrel=1/" -i aur-${NAME}/PKGBUILD
cd aur-${NAME}
updpkgsums && makepkg --printsrcinfo > .SRCINFO
makepkg -fsr
git add PKGBUILD .SRCINFO
git commit -a -m "Update to $(shards version)"
git push
