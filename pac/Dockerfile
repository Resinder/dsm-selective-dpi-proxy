# PAC server: busybox httpd (already in the Alpine base image) serves a
# proxy.pac rendered at start-up from environment variables, so nothing
# machine-specific is baked in.

ARG ALPINE_IMAGE=alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
FROM ${ALPINE_IMAGE}
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0555 /usr/local/bin/entrypoint.sh
USER 65534:65534
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
