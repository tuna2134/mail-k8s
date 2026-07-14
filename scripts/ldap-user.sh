#!/usr/bin/env bash
set -Eeuo pipefail
namespace=${NAMESPACE:-mail}
release=${RELEASE:-mailserver}
read -r -p 'Email address: ' email
read -r -s -p 'Password: ' password; echo
read -r -p 'Forward address (optional): ' forward
if [[ ! "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]]; then
  echo 'Invalid email address.' >&2
  exit 1
fi
if [[ -n "$forward" && ! "$forward" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]]; then
  echo 'Invalid forward address.' >&2
  exit 1
fi
localpart=${email%@*}
pod=$(kubectl -n "$namespace" get pod -l "app.kubernetes.io/name=${release},app.kubernetes.io/component=ldap" -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$namespace" exec -i "$pod" -- env EMAIL="$email" LOCALPART="$localpart" PASSWORD="$password" FORWARD="$forward" bash -c '
  hash=$(slappasswd -s "$PASSWORD")
  forwarding="# mail-forward is not set"
  if [[ -n "$FORWARD" ]]; then
    forwarding=$(printf "objectClass: mailForwardingUser\nmail-forward: %s" "$FORWARD")
  fi
  ldapadd -x -H ldap://127.0.0.1 -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" <<EOF
dn: uid=$EMAIL,ou=users,$LDAP_BASE_DN
objectClass: inetOrgPerson
objectClass: posixAccount
$forwarding
cn: $LOCALPART
sn: $LOCALPART
uid: $EMAIL
mail: $EMAIL
uidNumber: 5000
gidNumber: 5000
homeDirectory: /var/mail/${EMAIL#*@}/${EMAIL%@*}
userPassword: $hash
EOF'
unset password forward
