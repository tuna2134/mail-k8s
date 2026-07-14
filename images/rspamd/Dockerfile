FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends rspamd redis-server gettext-base tini ca-certificates && rm -rf /var/lib/apt/lists/*
COPY config/ /opt/rspamd/
COPY entrypoint.sh /usr/local/sbin/rspamd-entrypoint
RUN chmod 0755 /usr/local/sbin/rspamd-entrypoint
EXPOSE 11332
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/sbin/rspamd-entrypoint"]
