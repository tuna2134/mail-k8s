#!/bin/bash
set -Eeuo pipefail

: "${POSTGRES_HOST:?}" "${POSTGRES_PASSWORD:?}" "${LDAP_URI:?}" "${LDAP_BASE_DN:?}"
: "${LDAP_BIND_DN:?}" "${LDAP_BIND_PASSWORD:?}" "${IMAP_HOST:?}" "${SIEVE_HOST:?}" "${SMTP_HOST:?}"
: "${MAIL_DOMAIN:?}" "${SOGO_LANGUAGE:?}" "${SOGO_TIMEZONE:?}" "${SOGO_WORKERS:?}"

json_string() { printf %s "$1" | jq -Rs .; }

POSTGRES_PASSWORD_URL=$(printf %s "$POSTGRES_PASSWORD" | jq -sRr @uri)
database_url="postgresql://sogo:${POSTGRES_PASSWORD_URL}@${POSTGRES_HOST}:5432/sogo"

export PROFILE_URL_JSON FOLDER_INFO_URL_JSON SESSIONS_URL_JSON STORE_URL_JSON
export ACL_URL_JSON CACHE_URL_JSON LDAP_URI_JSON LDAP_BASE_DN_JSON LDAP_BIND_DN_JSON
export LDAP_BIND_PASSWORD_JSON IMAP_HOST_JSON SIEVE_HOST_JSON SMTP_HOST_JSON MAIL_DOMAIN_JSON
export SOGO_LANGUAGE_JSON SOGO_TIMEZONE_JSON
PROFILE_URL_JSON=$(json_string "${database_url}/sogo_user_profile")
FOLDER_INFO_URL_JSON=$(json_string "${database_url}/sogo_folder_info")
SESSIONS_URL_JSON=$(json_string "${database_url}/sogo_sessions_folder")
STORE_URL_JSON=$(json_string "${database_url}/sogo_store")
ACL_URL_JSON=$(json_string "${database_url}/sogo_acl")
CACHE_URL_JSON=$(json_string "${database_url}/sogo_cache_folder")
LDAP_URI_JSON=$(json_string "$LDAP_URI")
LDAP_BASE_DN_JSON=$(json_string "$LDAP_BASE_DN")
LDAP_BIND_DN_JSON=$(json_string "$LDAP_BIND_DN")
LDAP_BIND_PASSWORD_JSON=$(json_string "$LDAP_BIND_PASSWORD")
IMAP_HOST_JSON=$(json_string "$IMAP_HOST")
SIEVE_HOST_JSON=$(json_string "$SIEVE_HOST")
SMTP_HOST_JSON=$(json_string "$SMTP_HOST")
MAIL_DOMAIN_JSON=$(json_string "$MAIL_DOMAIN")
SOGO_LANGUAGE_JSON=$(json_string "$SOGO_LANGUAGE")
SOGO_TIMEZONE_JSON=$(json_string "$SOGO_TIMEZONE")

envsubst < /opt/sogo/sogo.conf.template > /etc/sogo/sogo.conf
chmod 0600 /etc/sogo/sogo.conf

until nc -z "$POSTGRES_HOST" 5432; do sleep 2; done
ldap_address=${LDAP_URI#ldap://}
ldap_host=${ldap_address%:*}
ldap_port=${ldap_address##*:}
until nc -z "$ldap_host" "$ldap_port"; do sleep 2; done

exec /usr/sbin/sogod \
  -WOUseWatchDog NO \
  -WONoDetach YES \
  -WOPort 0.0.0.0:20000 \
  -WOWorkersCount "$SOGO_WORKERS" \
  -WOPidFile /run/sogo/sogo.pid \
  -WOLogFile -
