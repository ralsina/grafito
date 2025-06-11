#!/bin/sh
pass github-registry | docker login ghcr.io -u ralsina --password-stdin
docker run --rm --privileged \
        multiarch/qemu-user-static \
        --reset -p yes
VERSION=$(shards version)
docker build . --platform=linux/arm64 --build-arg VERSION="${VERSION}" --build-arg ARCH=arm64 -t ghcr.io/ralsina/grafito-arm64:latest -t ghcr.io/ralsina/grafito-arm64:"${VERSION}" --push
docker build . --platform=linux/amd64 --build-arg VERSION="${VERSION}" --build-arg ARCH=amd64 -t ghcr.io/ralsina/grafito:latest -t ghcr.io/ralsina/grafito:"${VERSION}" --push
