#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

OPENSSL_VER="${OPENSSL_VER:-3.5.1}"
OPENSSL_PREFIX="/opt/openssl-3.5"
LIBOQS_PREFIX="/opt/liboqs"
OQSPROV_PREFIX="/opt/oqs-provider"
CLIENT_HOME="/opt/oqs-client"
CLIENT_CERT_DIR="${CLIENT_HOME}/certs"

SRC_ROOT="/usr/local/src"
OPENSSL_SRC="${SRC_ROOT}/openssl-${OPENSSL_VER}"
LIBOQS_SRC="${SRC_ROOT}/liboqs"
OQSPROV_SRC="${SRC_ROOT}/oqs-provider"

SERVER_USER="${SERVER_USER:-}"
SERVER_HOST="${SERVER_HOST:-}"
SERVER_CERT_PATH="${SERVER_CERT_PATH:-/opt/nginx-oqs/certs}"

case "$(uname -m)" in
  x86_64) OPENSSL_TARGET="linux-x86_64" ;;
  aarch64|arm64) OPENSSL_TARGET="linux-aarch64" ;;
  *)
    echo "Unsupported architecture: $(uname -m)"
    exit 1
    ;;
esac

apt-get update
apt-get install -y \
  build-essential \
  cmake \
  ninja-build \
  git \
  curl \
  ca-certificates \
  perl \
  pkg-config \
  zlib1g-dev \
  openssh-client

rm -rf "${OPENSSL_SRC}" "${LIBOQS_SRC}" "${OQSPROV_SRC}"
mkdir -p "${SRC_ROOT}" "${CLIENT_CERT_DIR}"

cd "${SRC_ROOT}"
curl -LO "https://www.openssl.org/source/openssl-${OPENSSL_VER}.tar.gz"
tar xf "openssl-${OPENSSL_VER}.tar.gz"

cd "${OPENSSL_SRC}"
./Configure \
  --prefix="${OPENSSL_PREFIX}" \
  --openssldir="${OPENSSL_PREFIX}/ssl" \
  "${OPENSSL_TARGET}" \
  shared

make -j"$(nproc)"
make install_sw

mkdir -p "${OPENSSL_PREFIX}/ssl"
cp /etc/ssl/openssl.cnf "${OPENSSL_PREFIX}/ssl/openssl.cnf" 2>/dev/null || true

OPENSSL_LIBDIR="${OPENSSL_PREFIX}/lib64"
if [[ ! -d "${OPENSSL_LIBDIR}" ]]; then
  OPENSSL_LIBDIR="${OPENSSL_PREFIX}/lib"
fi

printf '%s\n' \
  "${OPENSSL_LIBDIR}" \
  "${LIBOQS_PREFIX}/lib" \
  "${LIBOQS_PREFIX}/lib64" \
  | awk 'NF' | sort -u >/etc/ld.so.conf.d/oqs-client.conf

ldconfig

unset OPENSSL_CONF
unset OPENSSL_MODULES

git clone --depth 1 https://github.com/open-quantum-safe/liboqs.git "${LIBOQS_SRC}"

cmake -S "${LIBOQS_SRC}" -B "${LIBOQS_SRC}/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${LIBOQS_PREFIX}" \
  -DBUILD_SHARED_LIBS=ON

cmake --build "${LIBOQS_SRC}/build" -j"$(nproc)"
cmake --install "${LIBOQS_SRC}/build"

ldconfig

git clone --depth 1 https://github.com/open-quantum-safe/oqs-provider.git "${OQSPROV_SRC}"

cmake -S "${OQSPROV_SRC}" -B "${OQSPROV_SRC}/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${OQSPROV_PREFIX}" \
  -DOPENSSL_ROOT_DIR="${OPENSSL_PREFIX}" \
  -DCMAKE_PREFIX_PATH="${OPENSSL_PREFIX};${LIBOQS_PREFIX}" \
  -DOQS_DIR="${LIBOQS_PREFIX}"

cmake --build "${OQSPROV_SRC}/build" -j"$(nproc)"
env -u OPENSSL_CONF -u OPENSSL_MODULES cmake --install "${OQSPROV_SRC}/build" || true

OQSPROVIDER_SO=""
for p in \
  "${OQSPROV_PREFIX}/lib/ossl-modules/oqsprovider.so" \
  "${OQSPROV_PREFIX}/lib64/ossl-modules/oqsprovider.so" \
  "${OQSPROV_PREFIX}/lib/oqsprovider.so" \
  "${OQSPROV_PREFIX}/lib64/oqsprovider.so" \
  "${OQSPROV_SRC}/build/lib/oqsprovider.so"
do
  if [[ -f "$p" ]]; then
    OQSPROVIDER_SO="$p"
    break
  fi
done

if [[ -z "${OQSPROVIDER_SO}" ]]; then
  OQSPROVIDER_SO="$(find "${OQSPROV_PREFIX}" "${OQSPROV_SRC}/build" -type f -name 'oqsprovider.so' 2>/dev/null | head -n1)"
fi

if [[ -z "${OQSPROVIDER_SO}" ]]; then
  echo "Could not find oqsprovider.so"
  exit 1
fi

OQSPROVIDER_MODULE_DIR="$(dirname "${OQSPROVIDER_SO}")"

cat >"${OPENSSL_PREFIX}/ssl/openssl-oqs.cnf" <<EOF
config_diagnostics = 1
openssl_conf = openssl_init

[openssl_init]
providers = provider_sect

[provider_sect]
default = default_sect
base = base_sect
oqsprovider = oqsprovider_sect

[default_sect]
activate = 1

[base_sect]
activate = 1

[oqsprovider_sect]
activate = 1
module = ${OQSPROVIDER_SO}
EOF

cat >/etc/profile.d/oqs-client-env.sh <<EOF
export PATH=${OPENSSL_PREFIX}/bin:\$PATH
export LD_LIBRARY_PATH=${OPENSSL_LIBDIR}:${LIBOQS_PREFIX}/lib:${LIBOQS_PREFIX}/lib64:\${LD_LIBRARY_PATH:-}
export OPENSSL_CONF=${OPENSSL_PREFIX}/ssl/openssl-oqs.cnf
export OPENSSL_MODULES=${OQSPROVIDER_MODULE_DIR}
EOF

export PATH="${OPENSSL_PREFIX}/bin:${PATH}"
export LD_LIBRARY_PATH="${OPENSSL_LIBDIR}:${LIBOQS_PREFIX}/lib:${LIBOQS_PREFIX}/lib64:${LD_LIBRARY_PATH:-}"
export OPENSSL_CONF="${OPENSSL_PREFIX}/ssl/openssl-oqs.cnf"
export OPENSSL_MODULES="${OQSPROVIDER_MODULE_DIR}"
hash -r

echo "Verifying client stack"
which openssl
openssl version -a
ldd "$(command -v openssl)" | egrep 'ssl|crypto' || true
openssl list -providers
openssl list -signature-algorithms | grep -i mldsa || true
openssl list -tls-groups | egrep 'MLKEM|X25519|P-256|P-384' || true

if [[ -n "${SERVER_USER}" && -n "${SERVER_HOST}" ]]; then
  echo "Copying server certs from ${SERVER_USER}@${SERVER_HOST}:${SERVER_CERT_PATH}"
  for f in rsa.crt ecdsa.crt mldsa65.crt mldsa44.crt mldsa87.crt; do
    scp -o StrictHostKeyChecking=accept-new \
      "${SERVER_USER}@${SERVER_HOST}:${SERVER_CERT_PATH}/${f}" \
      "${CLIENT_CERT_DIR}/${f}"
  done
else
  echo "Skipping automatic cert copy."
  echo "Later, copy these files from the server into ${CLIENT_CERT_DIR}:"
  echo "  rsa.crt ecdsa.crt mldsa65.crt mldsa44.crt mldsa87.crt"
fi

cat >/usr/local/bin/oqs-sclient <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

HOST="127.0.0.1"
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
  --insecure           Do not pass -CAfile
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

if [[ -z "${PORT}" ]]; then
  echo "Port is required"
  usage
  exit 1
fi

GROUPS=""
CAFILE=""

case "${PORT}" in
  8443)
    GROUPS="X25519:P-256"
    CAFILE="${CLIENT_CERT_DIR}/rsa.crt"
    ;;
  8444)
    GROUPS="P-384:X25519"
    CAFILE="${CLIENT_CERT_DIR}/ecdsa.crt"
    ;;
  8445)
    GROUPS="MLKEM768"
    CAFILE="${CLIENT_CERT_DIR}/mldsa65.crt"
    ;;
  8446)
    GROUPS="MLKEM768"
    CAFILE="${CLIENT_CERT_DIR}/rsa.crt"
    ;;
  8447)
    GROUPS="X25519:P-256"
    CAFILE="${CLIENT_CERT_DIR}/mldsa65.crt"
    ;;
  8448)
    GROUPS="MLKEM512"
    CAFILE="${CLIENT_CERT_DIR}/mldsa44.crt"
    ;;
  8449)
    GROUPS="MLKEM1024"
    CAFILE="${CLIENT_CERT_DIR}/mldsa87.crt"
    ;;
  *)
    echo "Unknown port profile: ${PORT}"
    exit 1
    ;;
esac

if [[ -n "${OVERRIDE_GROUPS}" ]]; then
  GROUPS="${OVERRIDE_GROUPS}"
fi

if [[ -n "${OVERRIDE_CAFILE}" ]]; then
  CAFILE="${OVERRIDE_CAFILE}"
fi

CA_ARGS=()
if [[ "${INSECURE}" == "0" ]]; then
  if [[ ! -f "${CAFILE}" ]]; then
    echo "CA file not found: ${CAFILE}"
    echo "Copy the server certs into ${CLIENT_CERT_DIR} or use --cafile/--insecure"
    exit 1
  fi
  CA_ARGS=(-CAfile "${CAFILE}")
fi

echo "=============================================================="
echo "Host: ${HOST}"
echo "Port: ${PORT}"
echo "SNI: ${SERVERNAME}"
echo "Groups: ${GROUPS}"
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
    -groups ${GROUPS} \
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
      -groups ${GROUPS} \
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
echo "Client setup complete."
echo
echo "Helper commands installed:"
echo "  /usr/local/bin/oqs-sclient"
echo "  /usr/local/bin/oqs-test-all"
echo
echo "Example single-port test:"
echo "  oqs-sclient -h YOUR_SERVER_IP -p 8445 --showcert"
echo
echo "Example all-port test:"
echo "  oqs-test-all YOUR_SERVER_IP"
echo
echo "If you skipped automatic cert copy, copy these files from the server into ${CLIENT_CERT_DIR}:"
echo "  rsa.crt ecdsa.crt mldsa65.crt mldsa44.crt mldsa87.crt"
