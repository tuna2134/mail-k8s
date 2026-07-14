#!/bin/bash
set -Eeuo pipefail
: "${LDAP_BASE_DN:?}" "${LDAP_ADMIN_DN:?}" "${LDAP_ADMIN_PASSWORD:?}" "${LDAP_BIND_DN:?}" "${LDAP_BIND_PASSWORD:?}"
export LDAP_ROOTPW_HASH LDAP_BINDPW_HASH
LDAP_ROOTPW_HASH=$(slappasswd -s "$LDAP_ADMIN_PASSWORD")
LDAP_BINDPW_HASH=$(slappasswd -s "$LDAP_BIND_PASSWORD")
install -d -o openldap -g openldap /var/lib/ldap /run/slapd
envsubst < /opt/ldap/slapd.conf.template > /etc/ldap/slapd.conf
if [[ ! -f /var/lib/ldap/data.mdb ]]; then
  envsubst < /opt/ldap/bootstrap.ldif.template > /tmp/bootstrap.ldif
  slapadd -f /etc/ldap/slapd.conf -l /tmp/bootstrap.ldif
  chown -R openldap:openldap /var/lib/ldap
  rm -f /tmp/bootstrap.ldif
fi
exec /usr/sbin/slapd -d 0 -u openldap -g openldap -f /etc/ldap/slapd.conf -h 'ldap:/// ldapi:///'

