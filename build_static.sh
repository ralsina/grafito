#!/bin/bash
set -e

docker run --rm --privileged \
  multiarch/qemu-user-static \
  --reset -p yes

shards install

# Build for AMD64
docker build . -f Dockerfile.static -t grafito-builder
docker run -ti --rm -v "$PWD":/app --user="$UID" grafito-builder /bin/sh -c "cd /app && shards build --static --release && strip bin/grafito"
mv bin/grafito bin/grafito-static-linux-amd64

# Build for ARM64
docker build . -f Dockerfile.static --platform linux/arm64 -t grafito-builder
docker run -ti --rm -v "$PWD":/app --platform linux/arm64 --user="$UID" grafito-builder /bin/sh -c "cd /app && shards build --static --release && strip bin/grafito"
mv bin/grafito bin/grafito-static-linux-arm64
