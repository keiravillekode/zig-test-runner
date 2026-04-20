ARG REPO=alpine
ARG IMAGE=3.22.1@sha256:eafc1edb577d2e9b458664a15f23ea1c370214193226069eb22921169fc7e43f
FROM ${REPO}:${IMAGE} AS builder

ARG VERSION=0.16.0
ARG RELEASE=zig-x86_64-linux-${VERSION}

# We can't reliably pin the package versions on Alpine, so we ignore the linter warning.
# See https://gitlab.alpinelinux.org/alpine/abuild/-/issues/9996
# hadolint ignore=DL3018
RUN apk add --no-cache curl

WORKDIR /tmp
ADD https://ziglang.org/download/${VERSION}/${RELEASE}.tar.xz .
RUN tar -xvf ${RELEASE}.tar.xz \
    && rm -rf /tmp/${RELEASE}/doc \
    && rm -rf /tmp/${RELEASE}/lib/libc/include/any-windows-any \
    && mv /tmp/${RELEASE} /opt/zig

# Build the output-processing parser.
COPY src/parser.zig /tmp/parser.zig
RUN mkdir -p /opt/test-runner/bin \
    && /opt/zig/zig build-exe /tmp/parser.zig \
        -target x86_64-linux-musl -O ReleaseSafe \
        -femit-bin=/opt/test-runner/bin/exercism-parser

FROM ${REPO}:${IMAGE} AS runner

RUN addgroup ziggroup \
    && adduser --disabled-password --gecos ziggy --ingroup ziggroup ziggy
COPY --from=builder --chown=ziggy:ziggroup /opt/zig/ /opt/zig/
COPY --from=builder --chown=ziggy:ziggroup /opt/test-runner/bin/exercism-parser /opt/test-runner/bin/exercism-parser
ENV PATH=$PATH:/opt/zig

USER ziggy:ziggroup
WORKDIR /opt/test-runner
COPY --chown=ziggy:ziggroup bin/run.sh bin/run.sh
# Initialize a zig cache
COPY --chown=ziggy:ziggroup tests/example-success/example_success.zig init-zig-cache/
COPY --chown=ziggy:ziggroup tests/example-success/test_example_success.zig init-zig-cache/
RUN bin/run.sh example-success init-zig-cache init-zig-cache \
    && rm -rf init-zig-cache/
ENTRYPOINT ["/opt/test-runner/bin/run.sh"]
