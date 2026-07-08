FROM alpine:3.22 AS apk-static
RUN apk add --no-cache apk-tools-static

FROM n8nio/n8n:latest

USER root

COPY --from=apk-static /sbin/apk.static /sbin/apk.static

RUN /sbin/apk.static add --no-cache python3 py3-pip && \
    python3 --version && \
    ln -sf /usr/bin/python3 /usr/bin/python && \
    rm /sbin/apk.static

USER node
