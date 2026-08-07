#!/usr/bin/env bash
set -euo pipefail

HOST="127.0.0.1"
SERVERNAME="localhost"
CLIENT=""
TIMEOUT_SECS="5"
SHOW_CERT="1"
PORTS="all"
CERT_DIR="/opt/nginx-oqs/certs"

usage() {
  cat <<EOF
Usage: $0 -c /path/to/openssl [options]

Required:
  -c, --client PATH         Path to openssl binary to use

Optional:
  -h, --host HOST           Host to connect to (default: 127.0.0.1)
  -s, --servername NAME     TLS SNI servername (default: localhost)
  -t, --timeout SECONDS     Timeout per test (default: 5)
  -p, --ports LIST          Comma-separated ports or 'all' (default: all)
  --cert-dir DIR            Certificate directory (default: /opt/nginx-oqs/certs)
  --no-cert-inspect         Skip certificate inspection
  --help                    Show this help

Examples:
  $0 -c /opt/openssl-3.5/bin/openssl
  $0 -c /opt/openssl-3.5/bin/openssl -p 8445,8448,8449
  $0 -c /usr/bin/openssl -h 10.0.0.5 -s localhost --no-cert-inspect
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--client)
      CLIENT="$2"
      shift 2
      ;;
    -h|--host)
      HOST="$2"
      shift 2
      ;;
    -s|--servername)
      SERVERNAME="$2"
      shift 2
      ;;
    -t|--timeout)
      TIMEOUT_SECS="$2"
      shift 2
      ;;
    -p|--ports)
      PORTS="$2"
      shift 2
      ;;
    --cert-dir)
      CERT_DIR="$2"
      shift 2
      ;;
    --no-cert-inspect)
      SHOW_CERT="0"
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${CLIENT}" ]]; then
  echo "Error: --client is required"
  usage
  exit 1
fi

if [[ ! -x "${CLIENT}" ]]; then
  echo "Error: client is not executable: ${CLIENT}"
  exit 1
fi

declare -A GROUPS
declare -A CAFILES
declare -A LABELS

GROUPS[8443]="X25519:P-256"
CAFILES[8443]="${CERT_DIR}/rsa.crt"
LABELS[8443]="RSA cert + classical KEX"

GROUPS[8444]="P-384:X25519"
CAFILES[8444]="${CERT_DIR}/ecdsa.crt"
LABELS[8444]="ECDSA cert + classical KEX"

GROUPS[8445]="MLKEM768"
CAFILES[8445]="${CERT_DIR}/mldsa65.crt"
LABELS[8445]="ML-DSA-65 cert + MLKEM768"

GROUPS[8446]="MLKEM768"
CAFILES[8446]="${CERT_DIR}/rsa.crt"
LABELS[8446]="RSA cert + MLKEM768"

GROUPS[8447]="X25519:P-256"
CAFILES[8447]="${CERT_DIR}/mldsa65.crt"
LABELS[8447]="ML-DSA-65 cert + classical KEX"

GROUPS[8448]="MLKEM512"
CAFILES[8448]="${CERT_DIR}/mldsa44.crt"
LABELS[8448]="ML-DSA-44 cert + MLKEM512"

GROUPS[8449]="MLKEM1024"
CAFILES[8449]="${CERT_DIR}/mldsa87.crt"
LABELS[8449]="ML-DSA-87 cert + MLKEM1024"

ALL_PORTS=(8443 8444 8445 8446 8447 8448 8449)

if [[ "${PORTS}" == "all" ]]; then
  SELECTED_PORTS=("${ALL_PORTS[@]}")
else
  IFS=',' read -r -a SELECTED_PORTS <<<"${PORTS}"
fi

run_handshake_test() {
  local port="$1"
  local groups="$2"
  local cafile="$3"
  local label="$4"

  echo
  echo "================================================================"
  echo "Port: ${port}"
  echo "Profile: ${label}"
  echo "Groups: ${groups}"
  echo "CA file: ${cafile}"
  echo "----------------------------------------------------------------"

  if [[ ! -f "${cafile}" ]]; then
    echo "CA file not found: ${cafile}"
    return 1
  fi

  timeout "${TIMEOUT_SECS}"s bash -c "
    exec 3<&-
    printf '' | \"${CLIENT}\" s_client \
      -connect ${HOST}:${port} \
      -servername ${SERVERNAME} \
      -tls1_3 \
      -groups ${groups} \
      -CAfile ${cafile} \
      -brief 2>&1
  " | egrep 'Protocol version|Ciphersuite|Signature type|Server Temp Key|Verification|Verify return code|Peer certificate'

  local rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "Handshake test failed on port ${port}"
    return $rc
  fi
}

run_cert_inspect() {
  local port="$1"

  echo "Certificate details:"
  timeout "${TIMEOUT_SECS}"s bash -c "
    exec 3<&-
    printf '' | \"${CLIENT}\" s_client \
      -connect ${HOST}:${port} \
      -servername ${SERVERNAME} \
      -tls1_3 \
      -showcerts 2>/dev/null \
    | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
    | \"${CLIENT}\" x509 -text -noout
  " | egrep 'Subject:|Signature Algorithm:|Public Key Algorithm:'
}

echo "Using client: ${CLIENT}"
"${CLIENT}" version -a || true

for port in "${SELECTED_PORTS[@]}"; do
  if [[ -z "${GROUPS[$port]:-}" ]]; then
    echo
    echo "Skipping unknown port: ${port}"
    continue
  fi

  run_handshake_test "$port" "${GROUPS[$port]}" "${CAFILES[$port]}" "${LABELS[$port]}"

  if [[ "${SHOW_CERT}" == "1" ]]; then
    run_cert_inspect "$port"
  fi
done
