#!/bin/bash
set -e

# Pre-flight: the release must pass the same gates as CI, including
# the demo-mode suite. (This placeholder used to be commented out,
# which is how the empty-journal regression of v1.2.0/v1.3.0 reached
# two releases: the plain suite never executes the real subprocess
# path — see #61.)
crystal tool format --check src spec
[ -x bin/ameba ] || crystal build lib/ameba/bin/ameba.cr -o bin/ameba
bin/ameba src spec
crystal spec
crystal spec -Ddemo_mode

VERSION=$(git cliff --bumped-version --unreleased |cut -dv -f2)

sed "s/^version:.*$/version: $VERSION/g" -i shard.yml
./build_static.sh

# Smoke test (#61): the freshly built amd64 binary must return real
# journal rows from this host — guards against the empty-results
# regression that shipped in v1.2.0/v1.3.0. Skipped when the host has
# no journal or the binary cannot run locally (e.g. cross builds).
if command -v journalctl >/dev/null 2>&1 && [ "$(uname -m)" = "x86_64" ]; then
    smoke_port=$(( (RANDOM % 2000) + 4000 ))
    ./bin/grafito-static-linux-amd64 -p "$smoke_port" > /tmp/grafito-smoke.log 2>&1 &
    smoke_pid=$!
    smoke_rows=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1
        smoke_rows=$(curl -s "http://127.0.0.1:$smoke_port/logs?since=-24h" | grep -c 'class="log-row') || smoke_rows=0
        [ "$smoke_rows" -gt 0 ] && break
    done
    kill "$smoke_pid" 2>/dev/null || true
    if [ "${smoke_rows:-0}" -eq 0 ]; then
        echo "Smoke test failed: /logs returned no rows on a host with a journal (see /tmp/grafito-smoke.log)." >&2
        exit 1
    fi
    echo "Smoke test: /logs returned $smoke_rows rows."
fi

git add shard.yml
git add site/install.sh
git cliff --bump -o
git commit -a -m "bump: Release v$VERSION"
git tag "v$VERSION"
git push --tags
# Push main too: the bump commit is what the tag points at; a tag on
# a commit absent from origin is a footgun.
git push origin main
# Create the release without binaries: the Release workflow (triggered
# by the tag push above) builds them in CI and attaches them. v1.7.0
# shipped with no binaries because this manual upload went missing
# (#153), so wait here until CI has attached both — a red CI run now
# fails the release instead of silently shipping an empty release.
gh release create "v$VERSION" --title "Release v$VERSION" --notes "$(git cliff -l -s all)"
echo "Waiting for the Release workflow to attach binaries to v$VERSION..."
assets=0
for _ in $(seq 1 60); do
    assets=$(gh release view "v$VERSION" --json assets --jq 'length' 2>/dev/null || echo 0)
    [ "$assets" -ge 2 ] && break
    sleep 30
done
if [ "${assets:-0}" -lt 2 ]; then
    echo "Binaries were not attached within 30 minutes; check the Release workflow run." >&2
    exit 1
fi
bash -x upload_docker.sh
bash -x do_aur.sh
