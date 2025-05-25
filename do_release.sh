#!/bin/bash
set e

PKGNAME=$(basename "$PWD")
VERSION=$(git cliff --bumped-version |cut -dv -f2)

sed "s/^version:.*$/version: $VERSION/g" -i shard.yml
./build_static.sh
git add shard.yml
# hace lint test
git cliff --bump -o
git commit -a -m "bump: Release v$VERSION"
git tag "v$VERSION"
git push --tags
gh release create "v$VERSION" "bin/$PKGNAME-static-linux-amd64" "bin/$PKGNAME-static-linux-arm64" --title "Release v$VERSION" --notes "$(git cliff -l -s all)"
