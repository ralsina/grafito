#!/bin/bash
set -e

# Build a static arm64 binary with fake journal data for the demo site.
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
# rocky: the demo image plus jimmy-proxy (a local OpenAI-compatible proxy
# to ChatJimmy's free Llama 3.1 8B) that powers the demo's AI
# explanations without any API key. See demo-site/compose.yml.
ssh root@rocky "mkdir -p /data/stacks/grafito-demo"
scp demo-site/compose.yml root@rocky:/data/stacks/grafito-demo/compose.yml
ssh root@rocky "curl -fsSL https://raw.githubusercontent.com/Fadeleke57/jimmy-proxy/main/proxy.py -o /data/stacks/grafito-demo/proxy.py"
# --force-recreate covers both services: jimmy shares the grafito
# container's network namespace, so they must always be recreated
# together. Upstream proxy.py binds 127.0.0.1, which is correct for
# that setup - no patching needed.
ssh root@rocky "cd /data/stacks/grafito-demo && docker compose pull grafito && docker compose up -d --force-recreate"

make website
rsync -rav site/* root@rocky:/data/stacks/web/websites/grafito.ralsina.me/
