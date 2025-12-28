FROM ubuntu:latest
ARG ARCH=amd64
ARG VERSION
LABEL org.opencontainers.image.source="https://github.com/ralsina/grafito"
LABEL org.opencontainers.image.version="${VERSION}"

RUN apt update && apt -y upgrade && apt -y clean && apt install -y \
    systemd

RUN ln -s /usr/share/zoneinfo/UTC /etc/localtime -f
COPY bin/grafito-static-linux-${ARCH} /usr/local/bin/grafito
CMD ["/usr/local/bin/grafito", "-b", "0.0.0.0"]
