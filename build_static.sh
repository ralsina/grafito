#!/bin/bash
set -e

docker run --rm --privileged \
  multiarch/qemu-user-static \
  --reset -p yes

# Regenerate the concatenated and minified assets so the binaries
# embed what the sources say, not what was last committed (#70).
cat src/assets/css/*.css > src/assets/style.css
cat src/assets/js/*.js > src/assets/app.js
make minify

shards install

# Build for AMD64
docker build . -f Dockerfile.static -t grafito-builder
docker run -i --rm -v "$PWD":/app --user="$UID" grafito-builder /bin/sh -c "cd /app && shards build --static --release && strip bin/grafito"
mv bin/grafito bin/grafito-static-linux-amd64

# Build for ARM64
docker build . -f Dockerfile.static --platform linux/arm64 -t grafito-builder
docker run -i --rm -v "$PWD":/app --platform linux/arm64 --user="$UID" grafito-builder /bin/sh -c "cd /app && shards build --static --release && strip bin/grafito"
mv bin/grafito bin/grafito-static-linux-arm64
