sudo tee /usr/local/bin/oqs-sclient >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

HOST=""
PORT=""
SERVERNAME="localhost"
TIMEOUT_SECS="5"
SHOW_CERT="0"
INSECURE="0"
OVERRIDE_GROUPS=""
OVERRIDE_CAFILE=""
KEYLOG_ENABLED="1"
KEYLOG_FILE=""
KEYLOG_DIR="${HOME:-/tmp}/oqs-keylogs"

OPENSSL_PREFIX="/opt/openssl-3.5"
LIBOQS_PREFIX="/opt/liboqs"
OQSPROV_PREFIX="/opt/oqs-provider"
CLIENT_CERT_DIR="/opt/oqs-client/certs"

if [[ -d "${OPENSSL_PREFIX}/lib64" ]]; then
  OPENSSL_LIBDIR="${OPENSSL_PREFIX}/lib64"
else
  OPENSSL_LIBDIR="${OPENSSL_PREFIX}/lib"
fi

OQSPROVIDER_SO="$(find "${OQSPROV_PREFIX}" /usr/local/src/oqs-provider/build -name oqsprovider.so 2>/dev/null | head -n1)"
if [[ -z "${OQSPROVIDER_SO}" ]]; then
  echo "Could not find oqsprovider.so"
  exit 1
fi

export PATH="${OPENSSL_PREFIX}/bin:${PATH}"
export LD_LIBRARY_PATH="${OPENSSL_LIBDIR}:${LIBOQS_PREFIX}/lib:${LIBOQS_PREFIX}/lib64:${LD_LIBRARY_PATH:-}"
export OPENSSL_CONF="${OPENSSL_PREFIX}/ssl/openssl-oqs.cnf"
export OPENSSL_MODULES="$(dirname "${OQSPROVIDER_SO}")"

CLIENT_BIN="${OPENSSL_PREFIX}/bin/openssl"

usage() {
  cat <<EOU
Usage: oqs-sclient -h HOST -p PORT [options]

Required:
  -h HOST              Server IP or hostname
  -p PORT              Port to test

Optional:
  -s NAME              SNI servername (default: localhost)
  -t SECONDS           Timeout in seconds (default: 5)
  --showcert           Also print certificate Subject/Public Key/Signature
  --groups GROUPS      Override TLS groups for this connection
  --cafile FILE        Override CA file for this connection
  --insecure           Skip CA verification

Key log options:
  --keylog FILE        Write TLS secrets to this file
  --keylog-dir DIR     Auto-generate key log file under this directory
  --no-keylog          Disable key log generation

Known port profiles:
  8443 -> RSA cert + X25519:P-256
  8444 -> ECDSA cert + P-384:X25519
  8445 -> ML-DSA-65 cert + MLKEM768
  8446 -> RSA cert + MLKEM768
  8447 -> ML-DSA-65 cert + X25519:P-256
  8448 -> ML-DSA-44 cert + MLKEM512
  8449 -> ML-DSA-87 cert + MLKEM1024
EOU
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h)
      HOST="$2"
      shift 2
      ;;
    -p)
      PORT="$2"
      shift 2
      ;;
    -s)
      SERVERNAME="$2"
      shift 2
      ;;
    -t)
      TIMEOUT_SECS="$2"
      shift 2
      ;;
    --showcert)
      SHOW_CERT="1"
      shift
      ;;
    --groups)
      OVERRIDE_GROUPS="$2"
      shift 2
      ;;
    --cafile)
      OVERRIDE_CAFILE="$2"
      shift 2
      ;;
    --insecure)
      INSECURE="1"
      shift
      ;;
    --keylog)
      KEYLOG_FILE="$2"
      shift 2
      ;;
    --keylog-dir)
      KEYLOG_DIR="$2"
      shift 2
      ;;
    --no-keylog)
      KEYLOG_ENABLED="0"
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

if [[ -z "${HOST}" || -z "${PORT}" ]]; then
  usage
  exit 1
fi

TLS_GROUP_NAME=""
CAFILE=""

case "${PORT}" in
  8443)
    TLS_GROUP_NAME="X25519:P-256"
    CAFILE="${CLIENT_CERT_DIR}/rsa.crt"
    ;;
  8444)
    TLS_GROUP_NAME="P-384:X25519"
    CAFILE="${CLIENT_CERT_DIR}/ecdsa.crt"
    ;;
  8445)
    TLS_GROUP_NAME="MLKEM768"
    CAFILE="${CLIENT_CERT_DIR}/mldsa65.crt"
    ;;
  8446)
    TLS_GROUP_NAME="MLKEM768"
    CAFILE="${CLIENT_CERT_DIR}/rsa.crt"
    ;;
  8447)
    TLS_GROUP_NAME="X25519:P-256"
    CAFILE="${CLIENT_CERT_DIR}/mldsa65.crt"
    ;;
  8448)
    TLS_GROUP_NAME="MLKEM512"
    CAFILE="${CLIENT_CERT_DIR}/mldsa44.crt"
    ;;
  8449)
    TLS_GROUP_NAME="MLKEM1024"
    CAFILE="${CLIENT_CERT_DIR}/mldsa87.crt"
    ;;
  *)
    echo "Unknown port profile: ${PORT}"
    exit 1
    ;;
esac

if [[ -n "${OVERRIDE_GROUPS}" ]]; then
  TLS_GROUP_NAME="${OVERRIDE_GROUPS}"
fi

if [[ -n "${OVERRIDE_CAFILE}" ]]; then
  CAFILE="${OVERRIDE_CAFILE}"
fi

CA_ARGS=()
if [[ "${INSECURE}" == "0" ]]; then
  if [[ ! -f "${CAFILE}" ]]; then
    echo "CA file not found: ${CAFILE}"
    exit 1
  fi
  CA_ARGS=(-CAfile "${CAFILE}")
fi

KEYLOG_ARGS=()
if [[ "${KEYLOG_ENABLED}" == "1" ]]; then
  if [[ -z "${KEYLOG_FILE}" ]]; then
    mkdir -p "${KEYLOG_DIR}"
    SAFE_HOST="$(echo "${HOST}" | tr ':/' '__')"
    KEYLOG_FILE="${KEYLOG_DIR}/tls_${SAFE_HOST}_port${PORT}_$(date +%Y%m%d_%H%M%S).keys"
  else
    mkdir -p "$(dirname "${KEYLOG_FILE}")"
  fi
  : > "${KEYLOG_FILE}"
  chmod 600 "${KEYLOG_FILE}"
  KEYLOG_ARGS=(-keylogfile "${KEYLOG_FILE}")
fi

COMMON_ARGS=(
  s_client
  -connect "${HOST}:${PORT}"
  -servername "${SERVERNAME}"
  -tls1_3
  -groups "${TLS_GROUP_NAME}"
  "${CA_ARGS[@]}"
  "${KEYLOG_ARGS[@]}"
)

echo "=============================================================="
echo "Host: ${HOST}"
echo "Port: ${PORT}"
echo "SNI: ${SERVERNAME}"
echo "Groups: ${TLS_GROUP_NAME}"
if [[ "${INSECURE}" == "0" ]]; then
  echo "CA file: ${CAFILE}"
else
  echo "CA file: none (--insecure)"
fi
if [[ "${KEYLOG_ENABLED}" == "1" ]]; then
  echo "Key log: ${KEYLOG_FILE}"
else
  echo "Key log: disabled"
fi
echo "--------------------------------------------------------------"

timeout "${TIMEOUT_SECS}"s "${CLIENT_BIN}" \
  "${COMMON_ARGS[@]}" \
  -brief \
  < <(printf '') 2>&1 | egrep 'Protocol version|Ciphersuite|Signature type|Server Temp Key|Verification|Verify return code|Peer certificate' || true

if [[ "${SHOW_CERT}" == "1" ]]; then
  echo
  echo "Certificate details:"
  timeout "${TIMEOUT_SECS}"s "${CLIENT_BIN}" \
    "${COMMON_ARGS[@]}" \
    -showcerts \
    < <(printf '') 2>/dev/null \
  | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
  | "${CLIENT_BIN}" x509 -text -noout \
  | egrep 'Subject:|Signature Algorithm:|Public Key Algorithm:' || true
fi

if [[ "${KEYLOG_ENABLED}" == "1" ]]; then
  echo
  echo "TLS secrets written to: ${KEYLOG_FILE}"
fi
EOF

sudo chmod +x /usr/local/bin/oqs-sclient
