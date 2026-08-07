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

SRC_ROOT="/usr/local/src"
OPENSSL_SRC="${SRC_ROOT}/openssl-${OPENSSL_VER}"
LIBOQS_SRC="${SRC_ROOT}/liboqs"
OQSPROV_SRC="${SRC_ROOT}/oqs-provider"

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
  zlib1g-dev

rm -rf "${OPENSSL_SRC}" "${LIBOQS_SRC}" "${OQSPROV_SRC}"
mkdir -p "${SRC_ROOT}"

cd "${SRC_ROOT}"
curl -LO "https://www.openssl.org/source/openssl-${OPENSSL_VER}.tar.gz"
tar xf "openssl-${OPENSSL_VER}.tar.gz"

cd "${OPENSSL_SRC}"
./Configure \
  --prefix="${OPENSSL_PREFIX}" \
  --openssldir="${OPENSSL_PREFIX}/ssl" \
  linux-x86_64 \
  shared

make -j"$(nproc)"
make install_sw

OPENSSL_LIBDIR="${OPENSSL_PREFIX}/lib64"
if [[ ! -d "${OPENSSL_LIBDIR}" ]]; then
  OPENSSL_LIBDIR="${OPENSSL_PREFIX}/lib"
fi

cat >/etc/profile.d/openssl-oqs-env.sh <<EOF
export PATH=${OPENSSL_PREFIX}/bin:\$PATH
export LD_LIBRARY_PATH=${OPENSSL_LIBDIR}:${LIBOQS_PREFIX}/lib:${LIBOQS_PREFIX}/lib64:\${LD_LIBRARY_PATH:-}
EOF

export PATH="${OPENSSL_PREFIX}/bin:${PATH}"
export LD_LIBRARY_PATH="${OPENSSL_LIBDIR}:${LIBOQS_PREFIX}/lib:${LIBOQS_PREFIX}/lib64:${LD_LIBRARY_PATH:-}"
hash -r

git clone --depth 1 https://github.com/open-quantum-safe/liboqs.git "${LIBOQS_SRC}"

cmake -S "${LIBOQS_SRC}" -B "${LIBOQS_SRC}/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${LIBOQS_PREFIX}" \
  -DBUILD_SHARED_LIBS=ON

cmake --build "${LIBOQS_SRC}/build" -j"$(nproc)"
cmake --install "${LIBOQS_SRC}/build"

printf '%s\n' \
  "${OPENSSL_LIBDIR}" \
  "${LIBOQS_PREFIX}/lib" \
  "${LIBOQS_PREFIX}/lib64" \
  | awk 'NF' | sort -u >/etc/ld.so.conf.d/openssl-oqs.conf

ldconfig

git clone --depth 1 https://github.com/open-quantum-safe/oqs-provider.git "${OQSPROV_SRC}"

cmake -S "${OQSPROV_SRC}" -B "${OQSPROV_SRC}/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${OQSPROV_PREFIX}" \
  -DOPENSSL_ROOT_DIR="${OPENSSL_PREFIX}" \
  -DCMAKE_PREFIX_PATH="${OPENSSL_PREFIX};${LIBOQS_PREFIX}" \
  -DOQS_DIR="${LIBOQS_PREFIX}"

cmake --build "${OQSPROV_SRC}/build" -j"$(nproc)"
cmake --install "${OQSPROV_SRC}/build" || true

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

export OPENSSL_CONF="${OPENSSL_PREFIX}/ssl/openssl-oqs.cnf"

echo "===== VERIFY BINARY/LIBRARY STACK ====="
which openssl
openssl version -a
ldd "$(command -v openssl)" | egrep 'ssl|crypto' || true

echo "===== VERIFY PROVIDERS ====="
openssl list -providers

echo "===== VERIFY NATIVE ML-DSA ====="
openssl list -signature-algorithms | grep -i mldsa || true
openssl list -public-key-algorithms | grep -i mldsa || true

echo "===== VERIFY OQS PROVIDER ALGORITHMS ====="
openssl list -signature-algorithms -provider default -provider oqsprovider | grep -Ei 'mldsa|dilithium' || true

mkdir -p /root/mldsa-test

cat >/root/mldsa-test/req.cnf <<'EOF'
[req]
prompt = no
distinguished_name = dn
x509_extensions = v3_req
req_extensions = v3_req

[dn]
C = US
ST = Test
L = Test
O = PQ TLS Lab
OU = Demo
CN = localhost

[v3_req]
basicConstraints = CA:false
keyUsage = critical, digitalSignature, keyEncipherment, keyAgreement
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
IP.1 = 127.0.0.1
IP.2 = ::1
EOF

echo "===== GENERATE NATIVE ML-DSA CERT ====="
openssl genpkey -algorithm ML-DSA-65 -out /root/mldsa-test/mldsa65-native.key

openssl req -new -x509 \
  -key /root/mldsa-test/mldsa65-native.key \
  -out /root/mldsa-test/mldsa65-native.crt \
  -days 365 \
  -config /root/mldsa-test/req.cnf

echo "===== INSPECT CERT ====="
openssl x509 -in /root/mldsa-test/mldsa65-native.crt -text -noout | egrep 'Signature Algorithm|Public Key Algorithm' || true

echo "===== TEST s_server WITH NATIVE ML-DSA CERT ====="
echo "Run this in shell 1:"
echo
echo "export PATH=${OPENSSL_PREFIX}/bin:\$PATH"
echo "export LD_LIBRARY_PATH=${OPENSSL_LIBDIR}:${LIBOQS_PREFIX}/lib:${LIBOQS_PREFIX}/lib64:\${LD_LIBRARY_PATH:-}"
echo "export OPENSSL_CONF=${OPENSSL_PREFIX}/ssl/openssl-oqs.cnf"
echo "openssl s_server -accept 9443 -www -cert /root/mldsa-test/mldsa65-native.crt -key /root/mldsa-test/mldsa65-native.key"
echo
echo "Then run this in shell 2:"
echo
echo "export PATH=${OPENSSL_PREFIX}/bin:\$PATH"
echo "export LD_LIBRARY_PATH=${OPENSSL_LIBDIR}:${LIBOQS_PREFIX}/lib:${LIBOQS_PREFIX}/lib64:\${LD_LIBRARY_PATH:-}"
echo "export OPENSSL_CONF=${OPENSSL_PREFIX}/ssl/openssl-oqs.cnf"
echo "echo | openssl s_client -connect 127.0.0.1:9443 -tls1_3 -CAfile /root/mldsa-test/mldsa65-native.crt"
echo
echo "If native ML-DSA works here, then the OpenSSL stack is correct."
echo "After that, nginx must be rebuilt against ${OPENSSL_PREFIX}."
