#!/bin/bash
# The certificate keeper: Cloud Native Coverity's internal certificates (Secrets <release>-*-x509).
#
# One script, run three ways by the chart:
#   RUN=pre    pre-install/pre-upgrade hook: every certificate exists and is valid before the services start
#   RUN=post   post-install/post-upgrade hook: restart what still runs with old certificates (and in builtIn, take
#              over Secrets cert-manager managed until the upgrade removed its Certificates)
#   RUN=cron   the CronJob, on global.certificates.schedule: renew, restart, report
#
# MODE (global.certificates.mode):
#   builtIn      this script issues the certificates, renews them renewBefore ahead of their end, and rotates the CA
#                with an overlap (trust both CAs, re-issue from the new one, drop the old one)
#   certManager  cert-manager issues them (the chart's Issuers and Certificates); this script only prepares Secrets made
#                by an older chart for cert-manager, restarts and reports
#   external     the customer provides the Secrets; this script checks them, restarts and reports
#
# In every mode it restarts a Deployment when something its pods read only at startup has changed (their certificates
# and trust bundle, the scan services' connect-config), and logs how long each certificate has left. With
# NGINX_UPDATES it also restarts a Deployment whose TLS sidecar runs an older nginx than the sidecar's tag names now.
#
# Needs bash, openssl (1.1.1 or 3.x), curl, GNU date and coreutils; the chart runs it in the TLS sidecar's nginx image.
# Talks to the Kubernetes API with the pod's service account; never prints a private key or the token.

set -euo pipefail
umask 077

: "${MODE:?}" "${RUN:?}" "${RELEASE:?}" "${NAMESPACE:?}"
CONF=${CONF:-/etc/cnc-certificates}            # certificates.txt and consumers.txt, rendered by the chart
DURATION=${DURATION:-8760h}                    # service certificates
RENEW_BEFORE=${RENEW_BEFORE:-720h}
CA_DURATION=${CA_DURATION:-87600h}
CA_RENEW_BEFORE=${CA_RENEW_BEFORE:-8760h}
KEY_SIZE=${KEY_SIZE:-2048}
KEY_FORMAT=${KEY_FORMAT:-pkcs1}                # pkcs1 ("RSA PRIVATE KEY") or pkcs8 ("PRIVATE KEY")
CA_ROTATION=${CA_ROTATION:-}                   # change it to start a CA rotation now
WAIT_FOR_SCANS=${WAIT_FOR_SCANS:-true}         # don't restart while an analysis job runs...
FORCE_BEFORE=${FORCE_BEFORE:-72h}              # ...unless the running pods' certificates end sooner than this
SCAN_JOB_SELECTOR=${SCAN_JOB_SELECTOR:-}       # label selector of the analysis jobs
NGINX_UPDATES=${NGINX_UPDATES:-false}          # restart sidecars that run an older image than this pod's (same tag)
POD_NAME=${POD_NAME:-$(hostname)}              # this pod, to read the image it was started with
SIDECAR=${SIDECAR:-tls-sidecar}                # the chart's name for the TLS sidecar container
BACKDATE=${BACKDATE:-60s}                      # notBefore this far in the past, for clock skew
LOCK_WAIT=${LOCK_WAIT:-300}                    # seconds a hook waits for another run to finish
POST_WAIT=${POST_WAIT:-600}                    # seconds the post hook waits for a Deployment's rollout to finish
ORG=${ORG:-00000000-0000-0000-0000-000000000000}
COUNTRY=${COUNTRY:-US}

A=certificates.coverity.blackduck.com          # our annotations
NS=$NAMESPACE
STATUS_CM=$RELEASE-certificates-status
LOCK_CM=$RELEASE-certificates-lock
WORK=$(mktemp -d /tmp/keeper.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

log()  { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
warn() { log "WARNING: $*"; WARNINGS=$((WARNINGS + 1)); }
die()  { log "ERROR: $*"; exit 1; }
WARNINGS=0
NOW=$(date -u +%s)

# ---------------------------------------------------------------------------------------------------- time and text

dur() { # Go-style duration (8760h, 90m, 1h30m, 30s, 7d) -> seconds
  local s=$1 t=0
  [[ $s =~ ^[0-9]+$ ]] && { echo "$s"; return; }
  while [[ $s =~ ^([0-9]+)([dhms])(.*)$ ]]; do
    case ${BASH_REMATCH[2]} in
      d) t=$((t + BASH_REMATCH[1] * 86400)) ;; h) t=$((t + BASH_REMATCH[1] * 3600)) ;;
      m) t=$((t + BASH_REMATCH[1] * 60)) ;;    s) t=$((t + BASH_REMATCH[1])) ;;
    esac
    s=${BASH_REMATCH[3]}
  done
  [ -z "$s" ] || die "not a duration: $1"
  echo "$t"
}
iso()   { date -u -d "@$1" +%FT%TZ; }          # epoch -> 2027-11-18T03:17:00Z
epoch() { date -u -d "$1" +%s; }               # a date GNU date reads -> epoch
gtime() { date -u -d "@$1" +%Y%m%d%H%M%SZ; }   # epoch -> openssl ca's GeneralizedTime
left()  { # epoch -> "364 days", "5 h 3 min", "ended 2 min ago"
  local s=$(( $1 - NOW ))
  if [ "$s" -ge 172800 ] || [ "$s" -le -172800 ]; then echo "$((s / 86400)) days"
  elif [ "$s" -ge 0 ]; then echo "$((s / 3600)) h $(((s % 3600) / 60)) min"
  else echo "ended $(( -s / 60 )) min ago"; fi
}
sha()   { sha256sum | cut -c1-16; }

D=$(dur "$DURATION"); RB=$(dur "$RENEW_BEFORE"); CAD=$(dur "$CA_DURATION"); CARB=$(dur "$CA_RENEW_BEFORE")
FB=$(dur "$FORCE_BEFORE"); BD=$(dur "$BACKDATE")
[ "$RB" -lt "$D" ] || die "renewBefore ($RENEW_BEFORE) must be shorter than duration ($DURATION)"
[ "$CARB" -lt "$CAD" ] || die "ca.renewBefore ($CA_RENEW_BEFORE) must be shorter than ca.duration ($CA_DURATION)"

# --------------------------------------------------------------------------------------------- the Kubernetes API

if [ -z "${API:-}" ]; then
  H=${KUBERNETES_SERVICE_HOST:?}; [[ $H == *:* ]] && H="[$H]"
  API=https://$H:${KUBERNETES_SERVICE_PORT:-443}
fi
SA=${SA:-/var/run/secrets/kubernetes.io/serviceaccount}
printf 'Authorization: Bearer %s\n' "$(cat "$SA/token")" > "$WORK/auth"   # a header file: never on a command line

# kreq METHOD PATH [BODY-FILE] [CONTENT-TYPE]: the response body lands in $BODY, the HTTP status in $CODE
kreq() {
  # its own User-Agent: the API server pretty-prints JSON for one starting with "curl", and these readers need compact JSON
  local args=(-sS -o "$WORK/body" -w '%{http_code}' -X "$1" --cacert "$SA/ca.crt" -H "@$WORK/auth"
              -H 'Accept: application/json' -A cnc-certificate-keeper/1 --max-time 30)
  [ -n "${3:-}" ] && args+=(-H "Content-Type: ${4:-application/json}" --data-binary "@$3")
  CODE=$(curl "${args[@]}" "$API$2" 2>"$WORK/curl.err") || CODE=000
  BODY=$(cat "$WORK/body" 2>/dev/null || true)
  [ "$CODE" != 000 ] || BODY="curl: $(cat "$WORK/curl.err")"
  : > "$WORK/body"
}
kok() { # kreq, and stop unless the status is an accepted one ($OK, default 200 201)
  local ok=${OK:-200 201}; kreq "$@"
  [[ " $ok " == *" $CODE "* ]] || die "$1 $2: HTTP $CODE: $(printf '%s' "$BODY" | head -c 400)"
}
urlenc() { local s=$1; s=${s//%/%25}; s=${s//=/%3D}; s=${s//,/%2C}; s=${s//\//%2F}; s=${s// /%20}; printf '%s' "$s"; }

# The API answers compact JSON. These read the few fields this script needs from it.
rx()     { printf '%s' "$1" | sed 's/[][\.*^$/]/\\&/g'; }
jstr()   { printf '%s' "$1" | sed -n 's/.*"'"$(rx "$2")"'":"\([^"]*\)".*/\1/p'; }      # last "key":"value"
jnum()   { printf '%s' "$1" | sed -n 's/.*"'"$(rx "$2")"'":\([0-9]*\)[,}].*/\1/p'; }    # last "key":123
items()  { printf '%s\n' "$1" | sed 's/{"metadata":{"name":"/\n&/g' | sed 1d; }         # one list item per line (newline-ended, or read drops the last)
podname() { printf '%s' "$1" | sed -n 's/^{"metadata":{"name":"\([^"]*\)".*/\1/p'; }    # an item's name
lastwrite() { # newest managedFields time: when anything last wrote this object
  local t; t=$(printf '%s' "$1" | { grep -o '"time":"[^"]*"' || true; } | sed 's/.*:"\(.*\)"/\1/' | sort | tail -1)
  if [ -n "$t" ]; then epoch "$t"; else echo 0; fi
}

secret_path() { echo "/api/v1/namespaces/$NS/secrets/$1"; }
get_secret() { # name -> $SECRET (JSON), empty when missing
  kreq GET "$(secret_path "$1")"
  case $CODE in 200) SECRET=$BODY ;; 404) SECRET= ;; *) die "GET secret $1: HTTP $CODE: $(printf '%s' "$BODY" | head -c 300)" ;; esac
}
sdata() { jstr "$SECRET" "$1"; }             # a data key of $SECRET, base64
sann()  { jstr "$SECRET" "$A/$1"; }          # one of our annotations on $SECRET
b64d()  { base64 -d 2>/dev/null || true; }
b64e()  { base64 -w0; }

# ------------------------------------------------------------------------------------------------------- lock

# One run at a time: the hooks and the CronJob may overlap. The lock is a ConfigMap; one older than 15 minutes is stale.
LOCKED=0
lock() {
  local waited=0 since
  printf '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"%s","annotations":{"%s/holder":"%s","%s/since":"%s"}}}' \
    "$LOCK_CM" "$A" "${HOSTNAME:-keeper}" "$A" "$(iso "$NOW")" > "$WORK/lock.json"
  while :; do
    kreq POST "/api/v1/namespaces/$NS/configmaps" "$WORK/lock.json"
    [ "$CODE" = 201 ] && { LOCKED=1; return 0; }
    [ "$CODE" = 409 ] || die "lock: HTTP $CODE: $(printf '%s' "$BODY" | head -c 300)"
    kreq GET "/api/v1/namespaces/$NS/configmaps/$LOCK_CM"
    since=$(jstr "$BODY" "$A/since")
    if [ -n "$since" ] && [ $(( $(date -u +%s) - $(epoch "$since") )) -gt 900 ]; then
      log "lock: removing a stale lock from $since"; kreq DELETE "/api/v1/namespaces/$NS/configmaps/$LOCK_CM"; continue
    fi
    if [ "$RUN" = cron ]; then log "another run holds the lock (since $since): nothing to do this time"; exit 0; fi
    [ "$waited" -lt "$LOCK_WAIT" ] || die "another run has held the lock since $since"
    sleep 5; waited=$((waited + 5))
  done
}
unlock() { [ "$LOCKED" = 1 ] && kreq DELETE "/api/v1/namespaces/$NS/configmaps/$LOCK_CM"; LOCKED=0; }

# ---------------------------------------------------------------------------------------------------- openssl

# The certificates mirror the chart's own generator (cnc-common-infra): subject C=US, O=<zero UUID>, CN=<name>, RSA
# keys, the manifest's SANs, server and client use.
newkey() { # out-file
  openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:$KEY_SIZE" -out "$1.p8" 2>"$WORK/ossl.err" \
    || { cat "$WORK/ossl.err"; die "key generation failed"; }
  if [ "$KEY_FORMAT" = pkcs1 ]; then
    openssl rsa -in "$1.p8" -traditional -out "$1" 2>/dev/null || openssl rsa -in "$1.p8" -out "$1" 2>/dev/null
    rm -f "$1.p8"
  else mv "$1.p8" "$1"; fi
}
cnf() { # a fresh openssl ca configuration in $WORK/ca
  rm -rf "$WORK/ca"; mkdir -p "$WORK/ca/new"; : > "$WORK/ca/index.txt"
  openssl rand -hex 16 | sed 's/^./4/' > "$WORK/ca/serial"     # a random positive 128-bit serial
  cat > "$WORK/ca/ca.cnf" <<EOF
[ ca ]
default_ca = keeper
[ keeper ]
dir = $WORK/ca
database = \$dir/index.txt
new_certs_dir = \$dir/new
serial = \$dir/serial
default_md = sha256
policy = anything
unique_subject = no
copy_extensions = none
email_in_dn = no
[ anything ]
countryName = optional
organizationName = optional
commonName = optional
[ req ]
distinguished_name = dn
string_mask = nombstr
prompt = no
[ dn ]
EOF
}
extfile() { # kind usages sans -> $WORK/ext.cnf
  local kind=$1 usages=$2 sans=$3 eku="" ku san=""
  [[ ,$usages, == *,server,* ]] && eku="serverAuth"
  [[ ,$usages, == *,client,* ]] && eku="${eku:+$eku, }clientAuth"
  if [ "$kind" = leaf ]; then ku="critical, digitalSignature, keyEncipherment"
  else ku="critical, digitalSignature, keyEncipherment, keyCertSign, cRLSign"; fi
  [ -n "$sans" ] && san="subjectAltName = $(printf '%s' "$sans" | sed 's/[^,][^,]*/DNS:&/g; s/,/, /g')"
  {
    echo "[ ext ]"
    if [ "$kind" = leaf ]; then echo "basicConstraints = critical, CA:FALSE"; else echo "basicConstraints = critical, CA:TRUE"; fi
    echo "keyUsage = $ku"
    [ -z "$eku" ] || echo "extendedKeyUsage = $eku"
    echo "subjectKeyIdentifier = hash"
    [ "$kind" = ca ] || echo "authorityKeyIdentifier = keyid"
    [ -z "$san" ] || echo "$san"
  } > "$WORK/ext.cnf"
}
# sign CSR OUT NOTBEFORE NOTAFTER (ISSUER-CRT ISSUER-KEY | self KEY): openssl ca, which takes exact start and end
# times on every openssl (x509 -days can't say "ten minutes")
sign() {
  local csr=$1 out=$2 nb=$3 na=$4 args
  if [ "$5" = self ]; then args=(-selfsign -keyfile "$6"); else args=(-cert "$5" -keyfile "$6"); fi
  openssl ca -batch -config "$WORK/ca/ca.cnf" -extfile "$WORK/ext.cnf" -extensions ext -preserveDN -notext \
    -startdate "$(gtime "$nb")" -enddate "$(gtime "$na")" -in "$csr" -out "$out" "${args[@]}" >"$WORK/ossl.err" 2>&1 \
    || { cat "$WORK/ossl.err"; die "signing failed"; }
}
csr() { # key cn out
  cnf; printf 'C = %s\nO = %s\nCN = %s\n' "$COUNTRY" "$ORG" "$2" >> "$WORK/ca/ca.cnf"
  openssl req -new -config "$WORK/ca/ca.cnf" -key "$1" -out "$3" 2>"$WORK/ossl.err" || { cat "$WORK/ossl.err"; die "CSR failed"; }
}
not_after() { local e; e=$(openssl x509 -noout -enddate -in "$1" 2>/dev/null | cut -d= -f2 || true); if [ -n "$e" ]; then epoch "$e"; else echo 0; fi; }
fp() { { openssl x509 -noout -fingerprint -sha256 -in "$1" 2>/dev/null || true; } | cut -d= -f2 | tr -d : | cut -c1-16; }
first_cert() { awk '/-----BEGIN CERTIFICATE-----/{n++} n==1' "$1"; }
keymatch() { # crt key: the key belongs to the certificate
  local a b
  a=$({ openssl x509 -noout -pubkey -in "$1" 2>/dev/null || true; } | sha256sum); b=$({ openssl pkey -pubout -in "$2" 2>/dev/null || true; } | sha256sum)
  [ -n "$a" ] && [ "$a" = "$b" ] && [ "$a" != "$(printf '' | sha256sum)" ]
}

# --------------------------------------------------------------------------------------------------- the spec

# certificates.txt: secret|commonName|issuer secret or "self"|kind (ca, subca, leaf)|usages|SANs (comma separated)
declare -a CERTS=()
while IFS= read -r line; do
  [[ -z $line || $line == \#* ]] && continue
  CERTS+=("$line")
done < "$CONF/certificates.txt"
CA_SECRET=$(printf '%s\n' "${CERTS[@]}" | awk -F'|' '$3=="self"{print $1; exit}')
[ -n "$CA_SECRET" ] || die "certificates.txt names no CA"
spec_of() { printf '%s\n' "${CERTS[@]}" | awk -F'|' -v s="$1" '$1==s'; }
spec_hash() { printf '%s|%s|%s|%s' "$1" "$KEY_SIZE" "$KEY_FORMAT" "$D" | sha; }   # a new duration or key re-issues
ca_spec_hash() { spec_of "$CA_SECRET" | sha; }             # the CA's subject, names and use (its lifetime: at a rotation)

declare -a CHANGED=()
# write_secret NAME SPEC ISSUER-FP [EXTRA-ANNOTATIONS]: put $WORK/out/NAME.{crt,key,ca} into the Secret with our
# annotations. Creates it when missing; otherwise patches data and annotations only, so its type stays (Opaque from
# older charts, or kubernetes.io/tls).
write_secret() {
  local name=$1 spec=$2 issuer_fp=$3 extra=${4:-} crt key ca="" ann
  crt=$(b64e < "$WORK/out/$name.crt"); key=$(b64e < "$WORK/out/$name.key")
  [ -s "$WORK/out/$name.ca" ] && ca=$(b64e < "$WORK/out/$name.ca")
  ann=$(printf '"%s/managed-by":"keeper","%s/spec":"%s","%s/issuer":"%s","%s/not-after":"%s","%s/issued-at":"%s"%s' \
    "$A" "$A" "$(spec_hash "$spec")" "$A" "$issuer_fp" "$A" "$(iso "$(not_after "$WORK/out/$name.crt")")" "$A" "$(iso "$NOW")" "$extra")
  get_secret "$name"
  if [ -z "$SECRET" ]; then
    printf '{"apiVersion":"v1","kind":"Secret","type":"Opaque","metadata":{"name":"%s","annotations":{%s}},"data":{"tls.crt":"%s","tls.key":"%s"%s}}' \
      "$name" "$ann" "$crt" "$key" "${ca:+,\"ca.crt\":\"$ca\"}" > "$WORK/w.json"
    OK=201 kok POST "/api/v1/namespaces/$NS/secrets" "$WORK/w.json"
  else
    printf '{"metadata":{"resourceVersion":"%s","annotations":{%s}},"data":{"tls.crt":"%s","tls.key":"%s"%s}}' \
      "$(jstr "$SECRET" resourceVersion)" "$ann" "$crt" "$key" "${ca:+,\"ca.crt\":\"$ca\"}" > "$WORK/w.json"
    OK=200 kok PATCH "$(secret_path "$name")" "$WORK/w.json" application/merge-patch+json
  fi
  rm -f "$WORK/out/$name.key" "$WORK/w.json"
  CHANGED+=("$name")
}

# ---------------------------------------------------------------------------------------------- builtIn: the CA

# The CA Secret holds the active CA (tls.crt, tls.key), the trust bundle every service gets as its ca.crt (ca.crt), and
# during a rotation the next CA (next.crt, next.key) or the previous one (previous.crt). Its annotation "phase" is
#   stable   bundle = the active CA
#   trust    a next CA exists; bundle = active + next; the services restart to trust both
#   reissue  the next CA became active and everything was re-issued from it; bundle = active + previous until the
#            services restarted again
# and then stable again. Each step waits for the previous one's restarts to finish, at the next run.
new_ca() { # out-prefix: a new self-signed CA, valid CA_DURATION
  local s; s=$(spec_of "$CA_SECRET")
  newkey "$1.key"; csr "$1.key" "$(cut -d'|' -f2 <<< "$s")" "$WORK/ca.csr"
  extfile ca "$(cut -d'|' -f5 <<< "$s")" "$(cut -d'|' -f6 <<< "$s")"
  sign "$WORK/ca.csr" "$1.crt" $((NOW - BD)) $((NOW + CAD)) self "$1.key"
}
resign_ca() { # crt key out-prefix: the same CA (subject, key and key identifier) with a fresh validity of CA_DURATION
  local s ski; s=$(spec_of "$CA_SECRET")
  cnf
  openssl x509 -x509toreq -in "$1" -signkey "$2" -out "$WORK/ca.csr" 2>"$WORK/ossl.err" || { cat "$WORK/ossl.err"; die "x509toreq failed"; }
  extfile ca "$(cut -d'|' -f5 <<< "$s")" "$(cut -d'|' -f6 <<< "$s")"
  # Keep the old certificate's key identifier as it is: OpenSSL and Java match a certificate's authority key identifier
  # against its issuer's, and the generator of older charts didn't make it the usual SHA-1 of the key. With the same
  # subject, key and key identifier, every certificate the old CA signed verifies against this one.
  ski=$(openssl x509 -noout -ext subjectKeyIdentifier -in "$1" 2>/dev/null | sed -n 2p | tr -d ' ')
  if [[ $ski =~ ^[0-9A-Fa-f:]+$ ]]; then sed -i "s/^subjectKeyIdentifier = hash$/subjectKeyIdentifier = $ski/" "$WORK/ext.cnf"; fi
  sign "$WORK/ca.csr" "$3.crt" $((NOW - BD)) $((NOW + CAD)) self "$2"
  cp "$2" "$3.key"
}
ca_state() { # read the CA Secret into $WORK/ca-* files and CA_* variables
  get_secret "$CA_SECRET"; CA_JSON=$SECRET
  CA_PHASE=; CA_MANAGED=; CA_TOKEN=
  rm -f "$WORK"/ca-active.* "$WORK"/ca-next.* "$WORK"/ca-previous.crt "$WORK"/ca-bundle.crt
  [ -n "$SECRET" ] || return 0
  sdata tls.crt | b64d > "$WORK/ca-active.crt"; sdata tls.key | b64d > "$WORK/ca-active.key"
  sdata ca.crt | b64d > "$WORK/ca-bundle.crt"
  sdata next.crt | b64d > "$WORK/ca-next.crt"; sdata next.key | b64d > "$WORK/ca-next.key"
  sdata previous.crt | b64d > "$WORK/ca-previous.crt"
  [ -s "$WORK/ca-bundle.crt" ] || first_cert "$WORK/ca-active.crt" > "$WORK/ca-bundle.crt"
  CA_MANAGED=$(sann managed-by); CA_PHASE=$(sann phase); CA_TOKEN=$(sann rotation)
  [ -n "$CA_PHASE" ] || CA_PHASE=stable
}
ca_write() { # phase reason: write $WORK/out/ca.{crt,key,bundle} (and ca-next.*, ca-previous.crt) to the CA Secret
  local phase=$1 reason=$2 data ann
  data=$(printf '"tls.crt":"%s","tls.key":"%s","ca.crt":"%s"' "$(b64e < "$WORK/out/ca.crt")" "$(b64e < "$WORK/out/ca.key")" "$(b64e < "$WORK/out/ca.bundle")")
  if [ -s "$WORK/out/ca-next.crt" ]; then
    data="$data$(printf ',"next.crt":"%s","next.key":"%s"' "$(b64e < "$WORK/out/ca-next.crt")" "$(b64e < "$WORK/out/ca-next.key")")"
  else data="$data,\"next.crt\":null,\"next.key\":null"; fi
  if [ -s "$WORK/out/ca-previous.crt" ]; then data="$data$(printf ',"previous.crt":"%s"' "$(b64e < "$WORK/out/ca-previous.crt")")"
  else data="$data,\"previous.crt\":null"; fi
  ann=$(printf '"%s/managed-by":"keeper","%s/phase":"%s","%s/rotation":"%s","%s/not-after":"%s","%s/phase-since":"%s","%s/reason":"%s","%s/spec":"%s"' \
    "$A" "$A" "$phase" "$A" "${CA_ROTATION:-$CA_TOKEN}" "$A" "$(iso "$(not_after "$WORK/out/ca.crt")")" "$A" "$(iso "$NOW")" "$A" "$reason" "$A" "$(ca_spec_hash)")
  get_secret "$CA_SECRET"
  if [ -z "$SECRET" ]; then
    printf '{"apiVersion":"v1","kind":"Secret","type":"Opaque","metadata":{"name":"%s","annotations":{%s}},"data":{%s}}' \
      "$CA_SECRET" "$ann" "$(printf '%s' "$data" | sed 's/,"[a-z.]*":null//g')" > "$WORK/w.json"
    OK=201 kok POST "/api/v1/namespaces/$NS/secrets" "$WORK/w.json"
  else
    printf '{"metadata":{"resourceVersion":"%s","annotations":{%s}},"data":{%s}}' "$(jstr "$SECRET" resourceVersion)" "$ann" "$data" > "$WORK/w.json"
    OK=200 kok PATCH "$(secret_path "$CA_SECRET")" "$WORK/w.json" application/merge-patch+json
  fi
  rm -f "$WORK/out/ca.key" "$WORK/out/ca-next.key" "$WORK/out/ca-next.crt" "$WORK/out/ca-previous.crt" "$WORK/w.json"
  CHANGED+=("$CA_SECRET")
  log "$CA_SECRET: $reason (phase $phase; the active CA is valid until $(iso "$(not_after "$WORK/out/ca.crt")"))"
}

FORCE_REISSUE=0
ca_builtin() {
  mkdir -p "$WORK/out"; ca_state
  if [ -z "$CA_JSON" ]; then                                   # a new installation
    new_ca "$WORK/out/ca"; cp "$WORK/out/ca.crt" "$WORK/out/ca.bundle"; ca_write stable "new CA"; ca_state; return
  fi
  local na=0 ok=1 why=""
  if [ ! -s "$WORK/ca-active.crt" ] || [ ! -s "$WORK/ca-active.key" ] || ! keymatch "$WORK/ca-active.crt" "$WORK/ca-active.key"; then ok=0
  else na=$(not_after "$WORK/ca-active.crt"); fi
  if [ "$ok" = 0 ] || [ "$na" -le "$NOW" ]; then
    # Unusable or ended: nothing it signed is trusted any more, so no overlap. Same key and subject when there is a
    # key, so pods still holding the old CA certificate accept the new certificates; everything re-issued at once.
    if [ "$ok" = 1 ]; then resign_ca "$WORK/ca-active.crt" "$WORK/ca-active.key" "$WORK/out/ca"; else new_ca "$WORK/out/ca"; fi
    cp "$WORK/out/ca.crt" "$WORK/out/ca.bundle"
    ca_write stable "the CA had ended or was unusable: renewed, every certificate re-issued"; ca_state; FORCE_REISSUE=1; return
  fi
  if [ "$CA_MANAGED" != keeper ]; then
    # Made by an older chart (365 days, ending with its certificates): keep its key and subject and give it the full
    # CA lifetime. Everything it signed stays valid, and pods restarted from now on trust it for CA_DURATION.
    resign_ca "$WORK/ca-active.crt" "$WORK/ca-active.key" "$WORK/out/ca"
    cp "$WORK/out/ca.crt" "$WORK/out/ca.bundle"
    ca_write stable "adopted the CA made by an older chart (same key and subject)"; ca_state; FORCE_REISSUE=1; return
  fi
  if [ "$CA_PHASE" = stable ] && [ "$(jstr "$CA_JSON" "$A/spec")" != "$(ca_spec_hash)" ]; then
    # its names or use changed (made by a chart that named it differently): the same CA (key, subject, key
    # identifier) re-signed with the current ones; what it signed stays valid
    resign_ca "$WORK/ca-active.crt" "$WORK/ca-active.key" "$WORK/out/ca"; cp "$WORK/out/ca.crt" "$WORK/out/ca.bundle"
    ca_write stable "re-signed with the current names and use (same key and subject)"; ca_state; return
  fi
  case $CA_PHASE in
    stable)
      # a new value starts a rotation; an empty one (the default, or a value removed) never does
      [ -n "$CA_ROTATION" ] && [ "$CA_ROTATION" != "$CA_TOKEN" ] && why="ca.rotation changed to '$CA_ROTATION'"
      [ -z "$why" ] && [ $((na - NOW)) -lt "$CARB" ] && why="the CA ends $(iso "$na"), within ca.renewBefore"
      [ -n "$why" ] || return 0
      # 1. trust: a new CA next to the active one; every service gets both in ca.crt and restarts
      first_cert "$WORK/ca-active.crt" > "$WORK/out/ca.crt"; cp "$WORK/ca-active.key" "$WORK/out/ca.key"
      new_ca "$WORK/out/ca-next"
      cat "$WORK/out/ca.crt" "$WORK/out/ca-next.crt" > "$WORK/out/ca.bundle"
      ca_write trust "CA rotation started ($why): the services now trust both CAs"; ca_state ;;
    trust)
      all_loaded || { log "$CA_SECRET: the CA rotation waits until every service trusts both CAs"; return 0; }
      # 2. reissue: the next CA becomes active and everything is re-issued from it; the old CA stays trusted meanwhile
      cp "$WORK/ca-next.crt" "$WORK/out/ca.crt"; cp "$WORK/ca-next.key" "$WORK/out/ca.key"
      first_cert "$WORK/ca-active.crt" > "$WORK/out/ca-previous.crt"
      cat "$WORK/out/ca.crt" "$WORK/out/ca-previous.crt" > "$WORK/out/ca.bundle"
      ca_write reissue "CA rotation: the new CA is active, every certificate re-issued from it"; ca_state; FORCE_REISSUE=1 ;;
    reissue)
      all_loaded || { log "$CA_SECRET: the CA rotation waits until every service runs its new certificate"; return 0; }
      # 3. the old CA leaves the bundle
      cp "$WORK/ca-active.crt" "$WORK/out/ca.crt"; cp "$WORK/ca-active.key" "$WORK/out/ca.key"
      first_cert "$WORK/ca-active.crt" > "$WORK/out/ca.bundle"
      ca_write stable "CA rotation finished: the old CA is no longer trusted"; ca_state ;;
  esac
}

# ---------------------------------------------------------------------------------------- builtIn: the others

leaf_builtin() { # one certificates.txt line
  local spec=$1 name cn issuer kind usages sans icrt ikey ica ifp why="" na end iend
  IFS='|' read -r name cn issuer kind usages sans <<< "$spec"
  [ "$issuer" = self ] && return 0
  if [ "$issuer" = "$CA_SECRET" ]; then
    icrt=$WORK/ca-active.crt; ikey=$WORK/ca-active.key; ica=$WORK/ca-bundle.crt
  else                                                        # signed by a sub-CA (admin, by scan-service)
    get_secret "$issuer"
    sdata tls.crt | b64d > "$WORK/i.crt"; sdata tls.key | b64d > "$WORK/i.key"
    icrt=$WORK/i.crt; ikey=$WORK/i.key; first_cert "$WORK/i.crt" > "$WORK/i.ca"; ica=$WORK/i.ca
  fi
  ifp=$(fp "$icrt")
  get_secret "$name"
  if [ -z "$SECRET" ]; then why="missing"
  else
    sdata tls.crt | b64d > "$WORK/cur.crt"; sdata tls.key | b64d > "$WORK/cur.key"; sdata ca.crt | b64d > "$WORK/cur.ca"
    na=$(not_after "$WORK/cur.crt")
    if [ "$na" = 0 ] || ! keymatch "$WORK/cur.crt" "$WORK/cur.key"; then why="unreadable"
    elif [ "$na" -le "$NOW" ]; then why="it ended $(iso "$na")"
    elif [ "$(sann managed-by)" != keeper ]; then why="made by an older chart"
    elif [ "$FORCE_REISSUE" = 1 ]; then why="the CA changed"
    elif [ "$(sann issuer)" != "$ifp" ]; then why="its issuer changed"
    elif [ "$(sann spec)" != "$(spec_hash "$spec")" ]; then why="its settings changed"
    elif [ $((na - NOW)) -lt "$RB" ]; then why="it ends $(iso "$na"), within renewBefore"
    fi
  fi
  mkdir -p "$WORK/out"
  if [ -z "$why" ]; then
    # still good: only its trust bundle may have to follow the CA
    if ! cmp -s "$WORK/cur.ca" "$ica"; then
      cp "$WORK/cur.crt" "$WORK/out/$name.crt"; cp "$WORK/cur.key" "$WORK/out/$name.key"; cp "$ica" "$WORK/out/$name.ca"
      write_secret "$name" "$spec" "$ifp"
      log "$name: trust bundle updated ($(grep -c 'BEGIN CERTIFICATE' "$ica") CA certificate(s))"
    fi
    rm -f "$WORK/cur.key"
    return 0
  fi
  rm -f "$WORK/cur.key"
  newkey "$WORK/out/$name.key"; csr "$WORK/out/$name.key" "$cn" "$WORK/leaf.csr"
  extfile "$kind" "$usages" "$sans"
  end=$((NOW + D)); iend=$(not_after "$icrt")
  [ "$end" -le "$iend" ] || end=$iend                           # never outlive the issuer
  sign "$WORK/leaf.csr" "$WORK/out/$name.crt" $((NOW - BD)) "$end" "$icrt" "$ikey"
  cp "$ica" "$WORK/out/$name.ca"
  write_secret "$name" "$spec" "$ifp"
  log "$name: issued ($why), valid until $(iso "$end")"
}

cm_managed() { # some of the Secrets still carry cert-manager's annotation
  local spec
  for spec in "${CERTS[@]}"; do get_secret "${spec%%|*}"; [ -n "$(jstr "$SECRET" cert-manager.io/certificate-name)" ] && return 0; done
  return 1
}
builtin() {
  if [ "$RUN" = pre ] && cm_managed; then
    # Switching from certManager: its Certificates exist until this upgrade removes them, and cert-manager would write
    # over what the keeper writes now. The post hook takes the Secrets over, once they are gone.
    log "cert-manager still manages these Secrets: the post hook takes them over after the upgrade"; return 0
  fi
  ca_builtin
  local spec
  for spec in "${CERTS[@]}"; do leaf_builtin "$spec"; done        # in file order: a sub-CA before what it signs
  rm -f "$WORK"/*.key "$WORK"/i.key
}

# ------------------------------------------------------------------------------------- certManager and external

# cert-manager writes Secrets of type kubernetes.io/tls and can't change the type of an existing Secret. Older charts
# made them Opaque, so before the Certificates exist each Opaque one is recreated as kubernetes.io/tls with the same
# data. Running pods keep their mounted files; cert-manager then takes them over (the CA keeps its key).
certmanager_prepare() {
  local spec name type
  for spec in "${CERTS[@]}"; do
    name=${spec%%|*}; get_secret "$name"; [ -n "$SECRET" ] || continue
    type=$(jstr "$SECRET" type)
    [ "$type" = kubernetes.io/tls ] && continue
    if [ -z "$(sdata tls.crt)" ] || [ -z "$(sdata tls.key)" ]; then warn "$name: no tls.crt or tls.key, left for cert-manager to replace"; continue; fi
    printf '{"apiVersion":"v1","kind":"Secret","type":"kubernetes.io/tls","metadata":{"name":"%s","annotations":{"%s/converted-from":"%s","%s/converted-at":"%s"}},"data":{"tls.crt":"%s","tls.key":"%s","ca.crt":"%s"}}' \
      "$name" "$A" "$type" "$A" "$(iso "$NOW")" "$(sdata tls.crt)" "$(sdata tls.key)" "$(sdata ca.crt)" > "$WORK/w.json"
    OK=200 kok DELETE "$(secret_path "$name")"
    OK=201 kok POST "/api/v1/namespaces/$NS/secrets" "$WORK/w.json"
    rm -f "$WORK/w.json"
    CHANGED+=("$name")
    log "$name: recreated as kubernetes.io/tls (was $type) for cert-manager, same data"
  done
}

external_check() {
  local spec name bad=0 f
  for spec in "${CERTS[@]}"; do
    name=${spec%%|*}
    [ "$name" = "$CA_SECRET" ] && continue                      # nothing mounts the CA's own Secret
    get_secret "$name"
    if [ -z "$SECRET" ]; then log "$name: MISSING"; bad=1; continue; fi
    for f in tls.crt tls.key ca.crt; do [ -n "$(sdata "$f")" ] || { log "$name: no $f"; bad=1; }; done
    sdata tls.crt | b64d > "$WORK/x.crt"
    [ "$(not_after "$WORK/x.crt")" -gt "$NOW" ] || { log "$name: its certificate has ended or can't be read"; bad=1; }
  done
  [ "$bad" = 0 ] || die "certificates.mode is external: create the Secrets above (tls.crt, tls.key, ca.crt) first"
}

# ------------------------------------------------------------------------------------- restarts (every mode)

# consumers.txt: deployment|inputs; inputs are secret:<name> or configmap:<name>, comma separated: what the
# Deployment's pods read only when they start.
desired_fp() { # inputs -> fingerprint of what the pods should run with
  local i out=""
  for i in ${1//,/ }; do
    case $i in
      secret:*)    get_secret "${i#secret:}"; out="$out|$i:$(sdata tls.crt):$(sdata ca.crt)" ;;
      configmap:*) kreq GET "/api/v1/namespaces/$NS/configmaps/${i#configmap:}"
                   out="$out|$i:$(printf '%s' "$BODY" | sed -n 's/.*"data":\({[^}]*}\).*/\1/p')" ;;
    esac
  done
  printf '%s' "$out" | sha
}
inputs_changed_at() { # inputs -> newest write time among them
  local i t m=0
  for i in ${1//,/ }; do
    case $i in
      secret:*)    kreq GET "$(secret_path "${i#secret:}")" ;;
      configmap:*) kreq GET "/api/v1/namespaces/$NS/configmaps/${i#configmap:}" ;;
    esac
    [ "$CODE" = 200 ] || continue
    t=$(lastwrite "$BODY"); [ "$t" -gt "$m" ] && m=$t
  done
  echo "$m"
}
inputs_not_after() { # inputs -> earliest certificate end among the Secrets (0: none)
  local i m=0 t
  for i in ${1//,/ }; do
    [[ $i == secret:* ]] || continue
    get_secret "${i#secret:}"; sdata tls.crt | b64d > "$WORK/n.crt"
    t=$(not_after "$WORK/n.crt")
    if [ "$t" -gt 0 ] && { [ "$m" = 0 ] || [ "$t" -lt "$m" ]; }; then m=$t; fi
  done
  echo "$m"
}
all_loaded() { # every consumer has recorded the current inputs and finished its rollout
  local d inputs
  while IFS='|' read -r d inputs; do
    [[ -z $d || $d == \#* ]] && continue
    kreq GET "/apis/apps/v1/namespaces/$NS/deployments/$d"
    [ "$CODE" = 404 ] && continue
    [ "$CODE" = 200 ] || return 1
    local json=$BODY
    [ "$(jstr "$json" "$A/loaded")" = "$(desired_fp "$inputs")" ] || return 1
    rollout_done "$json" || return 1
  done < "$CONF/consumers.txt"
}
rollout_done() { # deployment JSON: the latest generation is rolled out and available
  local st="{${1##*\"status\":\{}" gen og want
  gen=$(printf '%s' "$1" | { grep -o '"generation":[0-9]*' || true; } | head -1 | cut -d: -f2)
  og=$(jnum "$st" observedGeneration)
  want=$(printf '%s' "$1" | sed -n 's/.*"spec":{"replicas":\([0-9]*\).*/\1/p'); [ -n "$want" ] || want=1
  [ "${og:-0}" -ge "${gen:-1}" ] || return 1
  [ "$want" = 0 ] && return 0
  [ "$(jnum "$st" updatedReplicas)" = "$want" ] && [ "$(jnum "$st" availableReplicas)" = "$want" ] && [ "$(jnum "$st" replicas)" = "$want" ]
}
dep_selector() { # deployment JSON -> its pods' label selector (a=b,c=d)
  printf '%s' "$1" | sed -n 's/.*"selector":{"matchLabels":{\([^}]*\)}.*/\1/p' | sed 's/"\([^"]*\)":"\([^"]*\)"/\1=\2/g'
}
pods_started_after() { # deployment-JSON epoch: every live pod of it (not terminating, not finished) started after epoch
  local sel pod st n=0
  sel=$(dep_selector "$1")
  [ -n "$sel" ] || return 1
  kreq GET "/api/v1/namespaces/$NS/pods?labelSelector=$(urlenc "$sel")"
  [ "$CODE" = 200 ] || return 1
  while IFS= read -r pod; do
    [[ $pod == *'"deletionTimestamp"'* ]] && continue
    # finished pods of older ReplicaSets can stay behind (phase Succeeded or Failed): they hold no certificate
    case $(jstr "$pod" phase) in Succeeded|Failed) continue ;; esac
    st=$(jstr "$pod" startTime)
    if [ -z "$st" ]; then WHY="$(podname "$pod") hasn't started"; return 1; fi
    if [ "$(epoch "$st")" -le "$2" ]; then WHY="$(podname "$pod") started $st, before the change at $(iso "$2")"; return 1; fi
    n=$((n + 1))
  done < <(items "$BODY")
  [ "$n" -gt 0 ] || WHY="no live pod"
  [ "$n" -gt 0 ]
}
scans_running() { # the number of active analysis jobs; 1 when they can't be read ("couldn't read" is not "none")
  [ -n "$SCAN_JOB_SELECTOR" ] || { echo 0; return; }
  kreq GET "/apis/batch/v1/namespaces/$NS/jobs?labelSelector=$(urlenc "$SCAN_JOB_SELECTOR")"
  if [ "$CODE" != 200 ]; then log "can't list the analysis jobs (HTTP $CODE): counting it as a scan running" >&2; echo 1; return; fi
  printf '%s' "$BODY" | { grep -o '"active":[1-9][0-9]*' || true; } | wc -l
}

declare -a PICKUP=()
declare -A RESTARTED=()
pickup() {
  local d inputs json want have changed na deadline running
  while IFS='|' read -r d inputs; do
    [[ -z $d || $d == \#* ]] && continue
    kreq GET "/apis/apps/v1/namespaces/$NS/deployments/$d"
    [ "$CODE" = 404 ] && continue
    [ "$CODE" = 200 ] || { warn "$d: can't read it (HTTP $CODE)"; continue; }
    json=$BODY
    want=$(desired_fp "$inputs"); have=$(jstr "$json" "$A/loaded")
    if [ "$want" = "$have" ]; then PICKUP+=("$d: up to date"); continue; fi
    na=$(inputs_not_after "$inputs")
    changed=$(inputs_changed_at "$inputs")
    deadline=$(jstr "$json" "$A/loaded-not-after"); [ -n "$deadline" ] && deadline=$(epoch "$deadline") || deadline=0
    if ! rollout_done "$json"; then
      # Still rolling out (an upgrade restarting it, say): its new pods may well start with the current certificates.
      # The post hook waits for the rollout; the CronJob looks again at its next run, unless the running ones end soon.
      while [ "$RUN" = post ] && [ "$(date -u +%s)" -lt $((NOW + POST_WAIT)) ] && ! rollout_done "$json"; do
        sleep 10                                                # POST_WAIT is one budget for the whole run
        kreq GET "/apis/apps/v1/namespaces/$NS/deployments/$d"; json=$BODY
      done
      if ! rollout_done "$json" && { [ "$deadline" = 0 ] || [ $((deadline - FB)) -gt "$NOW" ]; }; then
        log "$d: still rolling out; checked again at the next run"
        PICKUP+=("$d: rolling out"); continue
      fi
    fi
    WHY=""
    if rollout_done "$json" && pods_started_after "$json" "$changed"; then
      # its pods started after the last change (a new install, or an upgrade that restarted them): just record it
      printf '{"metadata":{"annotations":{"%s/loaded":"%s","%s/loaded-not-after":"%s"}}}' "$A" "$want" "$A" "$(iso "$na")" > "$WORK/p.json"
      OK=200 kok PATCH "/apis/apps/v1/namespaces/$NS/deployments/$d" "$WORK/p.json" application/merge-patch+json
      PICKUP+=("$d: already running the current certificates"); continue
    fi
    # it runs older certificates: restart it, unless a scan is running and its current certificates still have time
    running=0; [ "$WAIT_FOR_SCANS" = true ] && running=$(scans_running)
    if [ "$running" -gt 0 ] && [ "$deadline" -gt 0 ] && [ $((deadline - FB)) -gt "$NOW" ]; then
      log "$d: restart deferred while $running analysis job(s) run; its running certificates end $(iso "$deadline")"
      PICKUP+=("$d: restart deferred ($running scan(s) running)"); continue
    fi
    printf '{"metadata":{"annotations":{"%s/loaded":"%s","%s/loaded-not-after":"%s"}},"spec":{"template":{"metadata":{"annotations":{"%s/restarted-at":"%s"}}}}}' \
      "$A" "$want" "$A" "$(iso "$na")" "$A" "$(iso "$NOW")" > "$WORK/p.json"
    OK=200 kok PATCH "/apis/apps/v1/namespaces/$NS/deployments/$d" "$WORK/p.json" application/merge-patch+json
    log "$d: restarted to pick up its new certificates (${WHY:-its rollout is not done})"
    PICKUP+=("$d: restarted"); RESTARTED[$d]=1
  done < "$CONF/consumers.txt"
}

# ------------------------------------------------------------------------------------ nginx updates (every mode)

# The TLS sidecar follows a tag (cim.cimweb.tlsSidecar.version, "stable"), pulled with Always. This pod runs in the same
# image and has just pulled what the tag names now: a consumer whose sidecar runs another image is restarted, at the same
# moments and with the same wait for analysis jobs as a certificate restart. No deadline forces it: a run that finds
# scans running leaves it to the next run.
image_id() { # pod JSON, container name -> the imageID in that container's status (empty until it has one)
  # Compared as a whole: the same image always gives the same imageID. The status's "image" isn't used: the runtime
  # reports an image's first tag there, which can be another name for the same image.
  printf '%s' "$1" | sed 's/{"name":"/\n&/g' | { grep "^{\"name\":\"$2\"," || true; } \
    | { grep -o '"imageID":"[^"]*"' || true; } | sed -n 's/^"imageID":"\(.*\)"$/\1/p' | sed -n 1p
}
MY_ID=""; MY_START=0
my_image() { # this pod's image (its container's imageID) and start time
  local pod
  kreq GET "/api/v1/namespaces/$NS/pods?fieldSelector=$(urlenc "metadata.name=$POD_NAME")"
  [ "$CODE" = 200 ] || return 0
  pod=$(items "$BODY" | sed -n 1p)
  MY_ID=$(image_id "$pod" keeper)
  MY_START=$(jstr "$pod" startTime); if [ -n "$MY_START" ]; then MY_START=$(epoch "$MY_START"); else MY_START=0; fi
}
old_sidecar() { # deployment JSON -> "pod imageID" of a live pod, started before this one, whose sidecar runs another
                # image; empty when all are current, "?" when the pods can't be read
  local sel pod id st
  sel=$(dep_selector "$1")
  [ -n "$sel" ] || { echo "?"; return; }
  kreq GET "/api/v1/namespaces/$NS/pods?labelSelector=$(urlenc "$sel")"
  [ "$CODE" = 200 ] || { echo "?"; return; }
  while IFS= read -r pod; do
    [[ $pod == *'"deletionTimestamp"'* ]] && continue
    case $(jstr "$pod" phase) in Succeeded|Failed) continue ;; esac
    # a pod started after this one pulled the tag at least as recently: it isn't older
    st=$(jstr "$pod" startTime)
    if [ -n "$st" ] && [ "$(epoch "$st")" -ge "$MY_START" ]; then continue; fi
    id=$(image_id "$pod" "$SIDECAR")
    if [ -n "$id" ] && [ "$id" != "$MY_ID" ]; then printf '%s %s\n' "$(podname "$pod")" "$id"; return; fi
  done < <(items "$BODY")
}
nginx_pickup() {
  local d inputs json old running
  [ "$NGINX_UPDATES" = true ] || return 0
  my_image
  if [ -z "$MY_ID" ] || [ "$MY_START" = 0 ]; then
    warn "can't read this pod's own image: the sidecars' nginx isn't checked"; return 0
  fi
  log "nginx: the sidecar's tag is $MY_ID now"
  while IFS='|' read -r d inputs; do
    [[ -z $d || $d == \#* ]] && continue
    [ -n "${RESTARTED[$d]:-}" ] && continue                 # restarted for its certificates: it pulls the tag anyway
    kreq GET "/apis/apps/v1/namespaces/$NS/deployments/$d"
    [ "$CODE" = 404 ] && continue
    [ "$CODE" = 200 ] || { warn "$d: can't read it (HTTP $CODE)"; continue; }
    json=$BODY
    old=$(old_sidecar "$json")
    [ -n "$old" ] || continue
    if [ "$old" = "?" ]; then warn "$d: can't read its pods: its nginx isn't checked"; continue; fi
    if ! rollout_done "$json"; then
      log "$d: still rolling out; its nginx is checked at the next run"; PICKUP+=("$d: rolling out (nginx)"); continue
    fi
    running=0; [ "$WAIT_FOR_SCANS" = true ] && running=$(scans_running)
    if [ "$running" -gt 0 ]; then
      log "$d: nginx restart deferred while $running analysis job(s) run"
      PICKUP+=("$d: nginx restart deferred ($running scan(s) running)"); continue
    fi
    printf '{"spec":{"template":{"metadata":{"annotations":{"%s/restarted-at":"%s"}}}}}' "$A" "$(iso "$NOW")" > "$WORK/p.json"
    OK=200 kok PATCH "/apis/apps/v1/namespaces/$NS/deployments/$d" "$WORK/p.json" application/merge-patch+json
    log "$d: restarted for the current nginx (${old%% *} ran ${old#* })"
    PICKUP+=("$d: restarted for a newer nginx"); RESTARTED[$d]=1
  done < "$CONF/consumers.txt"
}

# ----------------------------------------------------------------------------------------------------- report

report() {
  local spec name cn na state lines w p esc
  lines=$(printf '%-36s %-26s %-21s %-18s %s' SECRET CN NOT-AFTER LEFT STATE)
  for spec in "${CERTS[@]}"; do
    IFS='|' read -r name cn _ <<< "$spec"
    get_secret "$name"
    if [ -z "$SECRET" ]; then state=MISSING; na=0
    else
      sdata tls.crt | b64d > "$WORK/r.crt"; na=$(not_after "$WORK/r.crt")
      if [ "$na" = 0 ]; then state=UNREADABLE
      elif [ "$na" -le "$NOW" ]; then state=ENDED
      elif [ "$name" = "$CA_SECRET" ] && [ $((na - NOW)) -lt "$CARB" ]; then state=ROTATION-DUE
      elif [ "$name" != "$CA_SECRET" ] && [ $((na - NOW)) -lt "$RB" ]; then state=RENEW-DUE
      else state=ok; fi
    fi
    case $state in
      ok) ;;
      RENEW-DUE|ROTATION-DUE)
        # builtIn renewed what was due in this run. cert-manager picks its own moment inside renewBefore (two thirds
        # of a certificate's life when that comes later), so only half of renewBefore left is overdue. external: due.
        lim=$RB; [ "$name" = "$CA_SECRET" ] && lim=$CARB
        case $MODE in
          certManager) [ $((na - NOW)) -lt $((lim / 2)) ] && warn "$name ends $(iso "$na") and cert-manager hasn't renewed it" ;;
          external) warn "$name ends $(iso "$na"): replace it before then" ;;
        esac ;;
      *) warn "$name: $state" ;;
    esac
    [ "$name" = "$CA_SECRET" ] && [ -n "$SECRET" ] && [ -n "$(sann phase)" ] && state="$state, CA phase $(sann phase)"
    if [ "$na" = 0 ]; then w=-; else w=$(iso "$na"); fi
    lines="$lines"$'\n'"$(printf '%-36s %-26s %-21s %-18s %s' "$name" "$cn" "$w" "$([ "$na" = 0 ] && echo - || left "$na")" "$state")"
  done
  printf '%s\n' "$lines"
  for p in "${PICKUP[@]}"; do log "restarts: $p"; done
  # the same table in a ConfigMap: kubectl get configmap <release>-certificates-status -o yaml
  esc=$(printf '%s' "$lines" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}')
  printf '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"%s"},"data":{"mode":"%s","checked-at":"%s","run":"%s","warnings":"%s","report":"%s"}}' \
    "$STATUS_CM" "$MODE" "$(iso "$NOW")" "$RUN" "$WARNINGS" "$esc" > "$WORK/s.json"
  kreq PUT "/api/v1/namespaces/$NS/configmaps/$STATUS_CM" "$WORK/s.json"
  [ "$CODE" = 404 ] && kreq POST "/api/v1/namespaces/$NS/configmaps" "$WORK/s.json"
  [[ $CODE == 20? ]] || warn "status ConfigMap: HTTP $CODE"
}

# -------------------------------------------------------------------------------------------------------- main

log "certificate keeper: mode $MODE, run $RUN, release $RELEASE in $NS; service certificates $DURATION (renewed $RENEW_BEFORE before the end), CA $CA_DURATION (rotated $CA_RENEW_BEFORE before), RSA $KEY_SIZE"
trap 'unlock; rm -rf "$WORK"' EXIT
lock
case $MODE in
  builtIn)     builtin ;;                                     # in the post hook, usually nothing left to do
  certManager) [ "$RUN" = pre ] && certmanager_prepare ;;
  external)    [ "$RUN" = pre ] && external_check ;;
  *) die "unknown mode $MODE (builtIn, certManager or external)" ;;
esac
# A pre hook runs before the upgrade applies the new Deployments, which restart what they change themselves; the post
# hook and the CronJob restart the rest.
[ "$RUN" = pre ] || { pickup; nginx_pickup; }
report
log "done: ${#CHANGED[@]} Secret(s) written, $WARNINGS warning(s)"
