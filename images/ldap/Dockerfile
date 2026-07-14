FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends slapd ldap-utils gettext-base tini ca-certificates && \
    rm -rf /var/lib/apt/lists/* /var/lib/ldap/* /etc/ldap/slapd.d/*
COPY slapd.conf.template bootstrap.ldif.template /opt/ldap/
COPY entrypoint.sh /usr/local/sbin/ldap-entrypoint
RUN chmod 0755 /usr/local/sbin/ldap-entrypoint
EXPOSE 389
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/sbin/ldap-entrypoint"]
