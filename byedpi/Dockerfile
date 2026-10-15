# ByeDPI (ciadpi) built from source, pinned to an exact upstream commit.
#
# The upstream project publishes no signed checksums and its release tags are
# unsigned, so the release binaries cannot be verified independently. Building
# from a pinned git commit gives a content-addressed, auditable source instead:
# the build fails if the checked-out tree does not hash to BYEDPI_COMMIT.

ARG ALPINE_IMAGE=alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc

FROM ${ALPINE_IMAGE} AS build
# v0.17.3 (https://github.com/hufrea/byedpi/releases/tag/v0.17.3)
ARG BYEDPI_COMMIT=7efde1b1296eaaa187b70e951894dde17527489c
ARG BYEDPI_REPO=https://github.com/hufrea/byedpi.git
RUN apk add --no-cache build-base linux-headers git
RUN git init /src \
 && cd /src \
 && git remote add origin "${BYEDPI_REPO}" \
 && git fetch --depth 1 origin "${BYEDPI_COMMIT}" \
 && git checkout --detach FETCH_HEAD \
 && test "$(git rev-parse HEAD)" = "${BYEDPI_COMMIT}" \
 && LDFLAGS=-static make \
 && ./ciadpi --version

FROM ${ALPINE_IMAGE}
ARG BYEDPI_COMMIT=7efde1b1296eaaa187b70e951894dde17527489c
LABEL org.opencontainers.image.title="byedpi" \
      org.opencontainers.image.source="https://github.com/hufrea/byedpi" \
      org.opencontainers.image.revision="${BYEDPI_COMMIT}" \
      org.opencontainers.image.licenses="MIT"
COPY --from=build /src/ciadpi /usr/local/bin/ciadpi
# Build context is the repo root (shared with the pac service) so both read the
# same hosts.default. The paths below are relative to that root.
COPY byedpi/healthcheck.sh /usr/local/bin/healthcheck.sh
COPY hosts.default /etc/byedpi/hosts.default
RUN chmod 0555 /usr/local/bin/ciadpi /usr/local/bin/healthcheck.sh \
 && chmod 0444 /etc/byedpi/hosts.default
USER 65534:65534
EXPOSE 1080
ENTRYPOINT ["/usr/local/bin/ciadpi"]
