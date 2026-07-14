#!/usr/bin/env bash
set -Eeuo pipefail
namespace=${NAMESPACE:-mail}
release=${RELEASE:-mailserver}
read -r -p 'Email address: ' email
read -r -s -p 'Password: ' password; echo
read -r -p 'Aliases (comma-separated, optional): ' aliases
read -r -p 'Forward address (optional): ' forward
aliases=${aliases//[[:space:]]/}
if [[ ! "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]]; then
  echo 'Invalid email address.' >&2
  exit 1
fi
if [[ -n "$forward" && ! "$forward" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]]; then
  echo 'Invalid forward address.' >&2
  exit 1
fi
if [[ -n "$aliases" ]]; then
  IFS=',' read -r -a alias_list <<< "$aliases"
  for alias in "${alias_list[@]}"; do
    if [[ ! "$alias" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ || "$alias" == "$email" ]]; then
      echo "Invalid or duplicate alias: $alias" >&2
      exit 1
    fi
  done
fi
localpart=${email%@*}
pod=$(kubectl -n "$namespace" get pod -l "app.kubernetes.io/name=${release},app.kubernetes.io/component=ldap" -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$namespace" exec -i "$pod" -- env EMAIL="$email" LOCALPART="$localpart" PASSWORD="$password" ALIASES="$aliases" FORWARD="$forward" bash -c '
  addresses="$EMAIL${ALIASES:+,$ALIASES}"
  IFS="," read -r -a address_list <<< "$addresses"
  for address in "${address_list[@]}"; do
    existing=$(ldapsearch -LLL -x -H ldap://127.0.0.1 -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" \
      -b "ou=users,$LDAP_BASE_DN" "(|(mail=$address)(mail-alias=$address))" dn)
    if [[ "$existing" == *"dn:"* ]]; then
      echo "Address already exists in LDAP: $address" >&2
      exit 1
    fi
  done
  hash=$(slappasswd -s "$PASSWORD")
  alias_attributes="# mail-alias is not set"
  if [[ -n "$ALIASES" ]]; then
    alias_attributes="objectClass: mailAliasUser"
    IFS="," read -r -a alias_list <<< "$ALIASES"
    for alias in "${alias_list[@]}"; do
      alias_attributes+=$(printf "\nmail-alias: %s" "$alias")
    done
  fi
  forwarding="# mail-forward is not set"
  if [[ -n "$FORWARD" ]]; then
    forwarding=$(printf "objectClass: mailForwardingUser\nmail-forward: %s" "$FORWARD")
  fi
  ldapadd -x -H ldap://127.0.0.1 -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" <<EOF
dn: uid=$EMAIL,ou=users,$LDAP_BASE_DN
objectClass: inetOrgPerson
objectClass: posixAccount
$alias_attributes
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
unset password aliases forward
