#!/bin/bash
set -e

# Build a static arm64 binary with fake journal data for the demo site.
docker run -i --rm -v "$PWD":/app --platform linux/arm64 --user="$UID" grafito-builder \
    /bin/sh -c "cd /app && shards build --static -Dfake_journal && strip bin/grafito"
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
# jimmy-proxy hardcodes 127.0.0.1; it must listen on all interfaces
# inside its container for the grafito container to reach it.
ssh root@rocky "sed -i 's/(\"127.0.0.1\", args.port)/(\"0.0.0.0\", args.port)/' /data/stacks/grafito-demo/proxy.py"
ssh root@rocky "cd /data/stacks/grafito-demo && docker compose pull grafito && docker compose up -d"

make website
rsync -rav site/* root@rocky:/data/stacks/web/websites/grafito.ralsina.me/
