# Tinyproxy from Alpine's signed package repository (alpine 3.20 ships 1.11.2,
# which supports SOCKS5 upstreams). The configuration is rendered at start-up
# from environment variables, so nothing machine-specific is baked in.

ARG ALPINE_IMAGE=alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
FROM ${ALPINE_IMAGE}
RUN apk add --no-cache tinyproxy \
 && tinyproxy -v
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY filter.default /usr/local/share/tinyproxy/filter.default
RUN chmod 0555 /usr/local/bin/entrypoint.sh \
 && chmod 0444 /usr/local/share/tinyproxy/filter.default
USER 65534:65534
EXPOSE 8888
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
