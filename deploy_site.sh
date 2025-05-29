#!/bin/sh
set -e

scp bin/grafito-fake-static-linux-arm64 root@rocky:/usr/local/bin/grafito-fake.1
ssh root@rocky "mv /usr/local/bin/grafito-fake.1 /usr/local/bin/grafito-fake"
ssh root@rocky "systemctl restart grafito-fake"
scp grafito-website.html rocky:/data/stacks/web/websites/grafito.ralsina.me/index.html
