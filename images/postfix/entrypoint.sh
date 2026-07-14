#!/bin/bash
set -Eeuo pipefail
: "${MAIL_HOSTNAME:?}" "${MAIL_PRIMARY_DOMAIN:?}" "${MAIL_DOMAINS:?}" "${LDAP_URI:?}" "${LDAP_BASE_DN:?}" "${LDAP_BIND_DN:?}" "${LDAP_BIND_PASSWORD:?}" "${DOVECOT_HOST:?}" "${RSPAMD_HOST:?}" "${TLS_CERT:?}" "${TLS_KEY:?}"
if [[ ! -d /var/spool/postfix/public ]]; then cp -a /var/spool/postfix.dist/. /var/spool/postfix/; fi
# Postfix's network-facing services run chrooted. Kubernetes supplies DNS and
# host configuration at container start, so keep the chroot's NSS files in sync
# on every start (including when the queue directory is restored from a PVC).
install -d -m 0755 /var/spool/postfix/etc
for f in hosts localtime nsswitch.conf resolv.conf services; do
  [[ -e "/etc/$f" ]] && cp -Lf "/etc/$f" "/var/spool/postfix/etc/$f"
done
vars='${MAIL_HOSTNAME} ${MAIL_PRIMARY_DOMAIN} ${MAIL_DOMAINS} ${LDAP_URI} ${LDAP_BASE_DN} ${LDAP_BIND_DN} ${LDAP_BIND_PASSWORD} ${DOVECOT_HOST} ${RSPAMD_HOST} ${TLS_CERT} ${TLS_KEY} ${MESSAGE_SIZE_LIMIT}'
# A fresh PVC hides the queue skeleton shipped in the image. Restore it only once.
for f in /opt/postfix/*.template; do envsubst "$vars" < "$f" > "/etc/postfix/$(basename "${f%.template}")"; done
chmod 0600 /etc/postfix/ldap-users.cf /etc/postfix/ldap-aliases.cf /etc/postfix/ldap-forward.cf
newaliases
postfix check
# Certbot runs in a sidecar. Reload without dropping active SMTP sessions on renewal.
watch_cert() { old=""; while sleep 300; do new=$(stat -c '%Y:%s' "$TLS_CERT" "$TLS_KEY" 2>/dev/null || true); [[ -n "$old" && "$new" != "$old" ]] && postfix reload || true; old=$new; done; }
watch_cert & watcher=$!
trap 'postfix stop || true; kill "$watcher" 2>/dev/null || true' TERM INT EXIT
exec postfix start-fg
