FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends dovecot-core dovecot-imapd dovecot-lmtpd dovecot-ldap dovecot-sieve dovecot-managesieved gettext-base tini ca-certificates && rm -rf /var/lib/apt/lists/* && groupadd -g 5000 vmail && useradd -u 5000 -g vmail -d /var/mail -s /usr/sbin/nologin vmail
COPY config/ /opt/dovecot/
COPY entrypoint.sh /usr/local/sbin/dovecot-entrypoint
RUN chmod 0755 /usr/local/sbin/dovecot-entrypoint
EXPOSE 24 993 1143 4190 12345
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/sbin/dovecot-entrypoint"]
