FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# SOGo's production APT repository requires a support subscription. The public
# nightly repository is used for this redistributable image and is signed by the
# same upstream key documented at sogo.nu.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gettext-base jq netcat-openbsd tini && \
    install -d -m 0755 /etc/apt/keyrings && \
    curl -fsSL "https://keys.openpgp.org/vks/v1/by-fingerprint/74FFC6D72B925A34B5D356BDF8A27B36A6E2EAE9" \
      -o /etc/apt/keyrings/sogo.asc && \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/sogo.asc] https://packages.sogo.nu/nightly/5/debian/ bookworm bookworm" \
      > /etc/apt/sources.list.d/sogo.list && \
    apt-get update && apt-get install -y --no-install-recommends sogo sope4.9-gdl1-postgresql && \
    rm -rf /var/lib/apt/lists/* && \
    install -d -o sogo -g sogo /run/sogo /var/lib/sogo /var/spool/sogo /etc/sogo

COPY sogo.conf.template /opt/sogo/sogo.conf.template
COPY entrypoint.sh /usr/local/sbin/sogo-entrypoint
RUN chmod 0755 /usr/local/sbin/sogo-entrypoint && chown sogo:sogo /etc/sogo

USER sogo
WORKDIR /var/lib/sogo
EXPOSE 20000
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/sbin/sogo-entrypoint"]
