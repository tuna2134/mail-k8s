#!/bin/bash
set -Eeuo pipefail
: "${MAIL_DOMAINS:?}"
cp /opt/rspamd/actions.conf /etc/rspamd/local.d/actions.conf
cp /opt/rspamd/worker-proxy.inc /etc/rspamd/local.d/worker-proxy.inc
cp /opt/rspamd/milter_headers.conf /etc/rspamd/local.d/milter_headers.conf
install -d -o _rspamd -g _rspamd /var/lib/rspamd/dkim /var/lib/redis

IFS=',' read -r -a domains <<< "$MAIL_DOMAINS"
DKIM_DOMAIN_CONFIG=
for domain in "${domains[@]}"; do
  if [[ ! "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
    echo "Invalid mail domain: $domain" >&2
    exit 1
  fi
  key="/var/lib/rspamd/dkim/${domain}.mail.key"
  dns="/var/lib/rspamd/dkim/${domain}.mail.dns.txt"
  # Generate each key once on the persistent volume. Publish only its dns.txt file.
  if [[ ! -s "$key" ]]; then
    rspamadm dkim_keygen -b 2048 -s mail -d "$domain" -k "$key" > "$dns"
  fi
  DKIM_DOMAIN_CONFIG+="  \"${domain}\" { path = \"${key}\"; selector = \"mail\"; }"$'\n'
done
export DKIM_DOMAIN_CONFIG
envsubst '${DKIM_DOMAIN_CONFIG}' < /opt/rspamd/dkim_signing.conf.template > /etc/rspamd/local.d/dkim_signing.conf
chown -R _rspamd:_rspamd /var/lib/rspamd
chmod 0600 /var/lib/rspamd/dkim/*.mail.key
rspamadm configtest
redis-server --daemonize yes --bind 127.0.0.1 --protected-mode yes
exec rspamd -f -u _rspamd -g _rspamd
