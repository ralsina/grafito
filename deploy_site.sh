#!/bin/bash
set -e

docker run -ti --rm -v "$PWD":/app --platform linux/arm64 --user="$UID" grafito-builder \
    /bin/sh -c "cd /app && shards build --static -Dfake_journal --release && strip bin/grafito"
mv bin/grafito bin/grafito-fake-static-linux-arm64

scp bin/grafito-fake-static-linux-arm64 root@rocky:/usr/local/bin/grafito-fake.1
ssh root@rocky "mv /usr/local/bin/grafito-fake.1 /usr/local/bin/grafito-fake"
ssh root@rocky "systemctl restart grafito-fake"
make website
rsync -rav site/* rocky:/data/stacks/web/websites/grafito.ralsina.me/
