#!/bin/bash
set -e

PKGNAME=$(basename "$PWD")
VERSION=$(git cliff --bumped-version --unreleased |cut -dv -f2)

sed "s/^version:.*$/version: $VERSION/g" -i shard.yml
git add shard.yml
# hace lint test
git cliff --bump -o
git commit -a -m "bump: Release v$VERSION"
git tag "v$VERSION"
git push --tags
bash -x do_aur.sh
