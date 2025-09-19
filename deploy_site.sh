#!/bin/bash
set -e

docker run -ti --rm -v "$PWD":/app --platform linux/arm64 --user="$UID" grafito-builder \
    /bin/sh -c "cd /app && shards build --static -Dfake_journal && strip bin/grafito"
mv bin/grafito bin/grafito-fake-static-linux-arm64

scp bin/grafito-fake-static-linux-arm64 root@rocky:/usr/local/bin/grafito-fake.1
scp grafito-fake.service root@rocky:/etc/systemd/system
ssh root@rocky "mv /usr/local/bin/grafito-fake.1 /usr/local/bin/grafito-fake"
ssh root@rocky "systemctl daemon-reload"
ssh root@rocky "systemctl restart grafito-fake"
make website
rsync -rav site/* root@rocky:/data/stacks/web/websites/grafito.ralsina.me/
