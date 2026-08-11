#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

SERVER_USER="${SERVER_USER:-}"
SERVER_HOST="${SERVER_HOST:-}"
SERVER_CERT_PATH="${SERVER_CERT_PATH:-/opt/nginx-oqs/certs}"

OPENSSL_PREFIX="/opt/openssl-3.5"
LIBOQS_PREFIX="/opt/liboqs"
OQSPROV_PREFIX="/opt/oqs-provider"
CLIENT_HOME="/opt/oqs-client"
CLIENT_CERT_DIR="${CLIENT_HOME}/certs"

if [[ -z "${SERVER_USER}" || -z "${SERVER_HOST}" ]]; then
  echo "Set SERVER_USER and SERVER_HOST"
  echo 'Example: sudo SERVER_USER=ubuntu SERVER_HOST=10.0.0.20 bash install_client_helpers.sh'
  exit 1
fi

if [[ ! -x "${OPENSSL_PREFIX}/bin/openssl" ]]; then
  echo "Missing ${OPENSSL_PREFIX}/bin/openssl"
  echo "Finish the OpenSSL/liboqs/oqs-provider setup first"
  exit 1
fi

mkdir -p "${CLIENT_CERT_DIR}"

echo "Copying server certs from ${SERVER_USER}@${SERVER_HOST}:${SERVER_CERT_PATH}"
for f in rsa.crt ecdsa.crt mldsa65.crt mldsa44.crt mldsa87.crt; do
  scp -o StrictHostKeyChecking=accept-new \
    "${SERVER_USER}@${SERVER_HOST}:${SERVER_CERT_PATH}/${f}" \
    "${CLIENT_CERT_DIR}/${f}"
done

cat >/usr/local/bin/oqs-sclient <<'EOF'
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
  --help               Show help

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

TLS_GROUPS=""
CAFILE=""

case "${PORT}" in
  8443)
    TLS_GROUPS="X25519:P-256"
    CAFILE="${CLIENT_CERT_DIR}/rsa.crt"
    ;;
  8444)
    TLS_GROUPS="P-384:X25519"
    CAFILE="${CLIENT_CERT_DIR}/ecdsa.crt"
    ;;
  8445)
    TLS_GROUPS="MLKEM768"
    CAFILE="${CLIENT_CERT_DIR}/mldsa65.crt"
    ;;
  8446)
    TLS_GROUPS="MLKEM768"
    CAFILE="${CLIENT_CERT_DIR}/rsa.crt"
    ;;
  8447)
    TLS_GROUPS="X25519:P-256"
    CAFILE="${CLIENT_CERT_DIR}/mldsa65.crt"
    ;;
  8448)
    TLS_GROUPS="MLKEM512"
    CAFILE="${CLIENT_CERT_DIR}/mldsa44.crt"
    ;;
  8449)
    TLS_GROUPS="MLKEM1024"
    CAFILE="${CLIENT_CERT_DIR}/mldsa87.crt"
    ;;
  *)
    echo "Unknown port profile: ${PORT}"
    exit 1
    ;;
esac

if [[ -n "${OVERRIDE_GROUPS}" ]]; then
  TLS_GROUPS="${OVERRIDE_GROUPS}"
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

echo "=============================================================="
echo "Host: ${HOST}"
echo "Port: ${PORT}"
echo "SNI: ${SERVERNAME}"
echo "Groups: ${TLS_GROUPS}"
if [[ "${INSECURE}" == "0" ]]; then
  echo "CA file: ${CAFILE}"
else
  echo "CA file: none (--insecure)"
fi
echo "--------------------------------------------------------------"

timeout "${TIMEOUT_SECS}"s bash -c "
  printf '' | \"${CLIENT_BIN}\" s_client \
    -connect ${HOST}:${PORT} \
    -servername ${SERVERNAME} \
    -tls1_3 \
    -groups ${TLS_GROUPS} \
    ${CA_ARGS[*]:-} \
    -brief 2>&1
" | egrep 'Protocol version|Ciphersuite|Signature type|Server Temp Key|Verification|Verify return code|Peer certificate' || true

if [[ "${SHOW_CERT}" == "1" ]]; then
  echo
  echo "Certificate details:"
  timeout "${TIMEOUT_SECS}"s bash -c "
    printf '' | \"${CLIENT_BIN}\" s_client \
      -connect ${HOST}:${PORT} \
      -servername ${SERVERNAME} \
      -tls1_3 \
      -groups ${TLS_GROUPS} \
      ${CA_ARGS[*]:-} \
      -showcerts 2>/dev/null \
    | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
    | \"${CLIENT_BIN}\" x509 -text -noout
  " | egrep 'Subject:|Signature Algorithm:|Public Key Algorithm:' || true
fi
EOF

chmod +x /usr/local/bin/oqs-sclient

cat >/usr/local/bin/oqs-test-all <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

HOST="${1:-}"
if [[ -z "${HOST}" ]]; then
  echo "Usage: oqs-test-all SERVER_IP_OR_HOSTNAME"
  exit 1
fi

for p in 8443 8444 8445 8446 8447 8448 8449; do
  oqs-sclient -h "${HOST}" -p "${p}" --showcert
  echo
done
EOF

chmod +x /usr/local/bin/oqs-test-all

echo
echo "Done."
echo "Copied certs to: ${CLIENT_CERT_DIR}"
echo "Installed:"
echo "  /usr/local/bin/oqs-sclient"
echo "  /usr/local/bin/oqs-test-all"
echo
echo "Example single-port test:"
echo "  oqs-sclient -h ${SERVER_HOST} -p 8445 --showcert"
echo
echo "Example all-port test:"
echo "  oqs-test-all ${SERVER_HOST}"
