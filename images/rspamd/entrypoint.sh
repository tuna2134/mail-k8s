#!/bin/bash
set -Eeuo pipefail
: "${MAIL_DOMAIN:?}"
cp /opt/rspamd/actions.conf /etc/rspamd/local.d/actions.conf
cp /opt/rspamd/worker-proxy.inc /etc/rspamd/local.d/worker-proxy.inc
cp /opt/rspamd/milter_headers.conf /etc/rspamd/local.d/milter_headers.conf
envsubst '${MAIL_DOMAIN}' < /opt/rspamd/dkim_signing.conf.template > /etc/rspamd/local.d/dkim_signing.conf
install -d -o _rspamd -g _rspamd /var/lib/rspamd/dkim /var/lib/redis
# Generate once on the persistent volume. Publish only the adjacent dns.txt file.
if [[ ! -s "/var/lib/rspamd/dkim/${MAIL_DOMAIN}.mail.key" ]]; then rspamadm dkim_keygen -b 2048 -s mail -d "$MAIL_DOMAIN" -k "/var/lib/rspamd/dkim/${MAIL_DOMAIN}.mail.key" > "/var/lib/rspamd/dkim/${MAIL_DOMAIN}.mail.dns.txt"; chown -R _rspamd:_rspamd /var/lib/rspamd; chmod 0600 "/var/lib/rspamd/dkim/${MAIL_DOMAIN}.mail.key"; fi
rspamadm configtest
redis-server --daemonize yes --bind 127.0.0.1 --protected-mode yes
exec rspamd -f -u _rspamd -g _rspamd
