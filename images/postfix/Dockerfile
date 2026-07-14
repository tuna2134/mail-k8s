FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && echo 'postfix postfix/mailname string localhost' | debconf-set-selections && echo 'postfix postfix/main_mailer_type string No configuration' | debconf-set-selections && apt-get install -y --no-install-recommends postfix postfix-ldap gettext-base tini ca-certificates netcat-openbsd && rm -rf /var/lib/apt/lists/*
COPY config/ /opt/postfix/
COPY entrypoint.sh /usr/local/sbin/postfix-entrypoint
RUN chmod 0755 /usr/local/sbin/postfix-entrypoint && cp -a /var/spool/postfix /var/spool/postfix.dist
EXPOSE 25 465 587
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/sbin/postfix-entrypoint"]
