FROM ubuntu:latest
ARG TARGETARCH
RUN apt update && apt -y upgrade && apt -y clean && apt install -y \
    systemd


RUN ln -s /usr/share/zoneinfo/UTC /etc/localtime -f
COPY ./bin/linux_${TARGETARCH}/grafito /usr/local/bin/grafito
CMD ["/usr/local/bin/grafito", "-b", "0.0.0.0"]
