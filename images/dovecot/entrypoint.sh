#!/bin/bash
set -Eeuo pipefail
: "${LDAP_URI:?}" "${LDAP_BASE_DN:?}" "${LDAP_BIND_DN:?}" "${LDAP_BIND_PASSWORD:?}" "${TLS_CERT:?}" "${TLS_KEY:?}"
# Render runtime-only values; keep Dovecot's own %u/%d variables untouched.
envsubst '${POSTMASTER_ADDRESS} ${TLS_CERT} ${TLS_KEY}' < /opt/dovecot/dovecot.conf.template > /etc/dovecot/dovecot.conf
envsubst '${LDAP_URI} ${LDAP_BASE_DN} ${LDAP_BIND_DN} ${LDAP_BIND_PASSWORD}' < /opt/dovecot/dovecot-ldap.conf.ext.template > /etc/dovecot/dovecot-ldap.conf.ext
chmod 0600 /etc/dovecot/dovecot-ldap.conf.ext
install -d -o vmail -g vmail /var/mail
doveconf -n >/dev/null
# The certificate PVC is updated by the Certbot sidecar in the Postfix Pod.
watch_cert() { old=""; while sleep 300; do new=$(stat -c '%Y:%s' "$TLS_CERT" "$TLS_KEY" 2>/dev/null || true); [[ -n "$old" && "$new" != "$old" ]] && doveadm reload || true; old=$new; done; }
watch_cert & watcher=$!
trap 'doveadm stop || true; kill "$watcher" 2>/dev/null || true' TERM INT EXIT
exec dovecot -F
