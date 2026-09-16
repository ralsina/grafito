#!/bin/bash
set -e

# Build a static arm64 binary with fake journal data for the demo site.
# Regenerate the concatenated and minified assets so the binaries
# embed what the sources say, not what was last committed (#70).
cat src/assets/css/*.css > src/assets/style.css
cat src/assets/js/*.js > src/assets/app.js
make minify

docker run -i --rm -v "$PWD":/app --platform linux/arm64 --user="$UID" grafito-builder \
    /bin/sh -c "cd /app && shards build --static -Ddemo_mode && strip bin/grafito"
mv bin/grafito bin/grafito-fake-static-linux-arm64

# Package it as the demo image and push it to ghcr.io.
VERSION=$(shards version)
pass github-registry | docker login ghcr.io -u ralsina --password-stdin
docker build . -f Dockerfile.demo --platform linux/arm64 \
    --build-arg VERSION="${VERSION}" \
    -t ghcr.io/ralsina/grafito-demo-arm64:latest \
    -t ghcr.io/ralsina/grafito-demo-arm64:"${VERSION}" --push

# The demo runs as a docker compose stack in /data/stacks/grafito-demo on
# rocky: the demo image alone; AI explanations come from the built-in
# ChatJimmy provider, so there is no proxy sidecar anymore.
# See demo-site/compose.yml.
ssh root@rocky "mkdir -p /data/stacks/grafito-demo"
scp demo-site/compose.yml root@rocky:/data/stacks/grafito-demo/compose.yml
# Remove the proxy.py left behind by the old jimmy-proxy sidecar.
ssh root@rocky "rm -f /data/stacks/grafito-demo/proxy.py"
# --remove-orphans drops the retired jimmy container; --force-recreate
# picks up the new compose file in one step.
ssh root@rocky "cd /data/stacks/grafito-demo && docker compose pull && docker compose up -d --force-recreate --remove-orphans"

make website
rsync -rav site/* root@rocky:/data/stacks/web/websites/grafito.ralsina.me/
