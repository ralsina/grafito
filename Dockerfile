FROM ubuntu:latest
ARG ARCH=amd64
ARG VERSION
LABEL org.opencontainers.image.source="https://github.com/ralsina/grafito"
LABEL org.opencontainers.image.version="${VERSION}"

RUN apt update && apt -y upgrade && apt install -y --no-install-recommends \
    systemd \
    docker.io \
    docker-compose-v2 \
  && apt -y clean && rm -rf /var/lib/apt/lists/*

RUN ln -s /usr/share/zoneinfo/UTC /etc/localtime -f
COPY bin/grafito-static-linux-${ARCH} /usr/local/bin/grafito
EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/grafito", "-b", "0.0.0.0"]
