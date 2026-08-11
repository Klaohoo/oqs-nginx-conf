#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

OPENSSL_PREFIX="/opt/openssl-3.5"
LIBOQS_PREFIX="/opt/liboqs"
OQSPROV_PREFIX="/opt/oqs-provider"

SRC_ROOT="/usr/local/src"
LIBOQS_SRC="${SRC_ROOT}/liboqs"
OQSPROV_SRC="${SRC_ROOT}/oqs-provider"

if [[ ! -x "${OPENSSL_PREFIX}/bin/openssl" ]]; then
  echo "Missing ${OPENSSL_PREFIX}/bin/openssl"
  echo "Install/build OpenSSL first"
  exit 1
fi

if [[ ! -f "${OPENSSL_PREFIX}/include/openssl/ssl.h" ]]; then
  echo "Missing OpenSSL headers in ${OPENSSL_PREFIX}/include"
  exit 1
fi

if [[ -d "${OPENSSL_PREFIX}/lib64" ]]; then
  OPENSSL_LIBDIR="${OPENSSL_PREFIX}/lib64"
else
  OPENSSL_LIBDIR="${OPENSSL_PREFIX}/lib"
fi

OPENSSL_SSL_LIBRARY="${OPENSSL_LIBDIR}/libssl.so"
OPENSSL_CRYPTO_LIBRARY="${OPENSSL_LIBDIR}/libcrypto.so"

if [[ ! -f "${OPENSSL_SSL_LIBRARY}" && -f "${OPENSSL_LIBDIR}/libssl.so.3" ]]; then
  OPENSSL_SSL_LIBRARY="${OPENSSL_LIBDIR}/libssl.so.3"
fi

if [[ ! -f "${OPENSSL_CRYPTO_LIBRARY}" && -f "${OPENSSL_LIBDIR}/libcrypto.so.3" ]]; then
  OPENSSL_CRYPTO_LIBRARY="${OPENSSL_LIBDIR}/libcrypto.so.3"
fi

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

export PATH="${OPENSSL_PREFIX}/bin:${PATH}"
export LD_LIBRARY_PATH="${OPENSSL_LIBDIR}:${LIBOQS_PREFIX}/lib:${LIBOQS_PREFIX}/lib64:${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="${OPENSSL_LIBDIR}/pkgconfig:${LIBOQS_PREFIX}/lib/pkgconfig:${LIBOQS_PREFIX}/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"

unset OPENSSL_CONF
unset OPENSSL_MODULES

mkdir -p "${SRC_ROOT}"

rm -rf "${LIBOQS_SRC}"
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
  | awk 'NF' | sort -u >/etc/ld.so.conf.d/oqs-client.conf

ldconfig

rm -rf "${OQSPROV_SRC}"
git clone --depth 1 https://github.com/open-quantum-safe/oqs-provider.git "${OQSPROV_SRC}"

cmake -S "${OQSPROV_SRC}" -B "${OQSPROV_SRC}/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${OQSPROV_PREFIX}" \
  -DCMAKE_PREFIX_PATH="${OPENSSL_PREFIX};${OPENSSL_LIBDIR};${LIBOQS_PREFIX}" \
  -DOPENSSL_ROOT_DIR="${OPENSSL_PREFIX}" \
  -DOPENSSL_INCLUDE_DIR="${OPENSSL_PREFIX}/include" \
  -DOPENSSL_SSL_LIBRARY="${OPENSSL_SSL_LIBRARY}" \
  -DOPENSSL_CRYPTO_LIBRARY="${OPENSSL_CRYPTO_LIBRARY}" \
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
  echo "Could not find oqsprovider.so after build/install"
  exit 1
fi

OQSPROVIDER_MODULE_DIR="$(dirname "${OQSPROVIDER_SO}")"

mkdir -p "${OPENSSL_PREFIX}/ssl"
cp /etc/ssl/openssl.cnf "${OPENSSL_PREFIX}/ssl/openssl.cnf" 2>/dev/null || true

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

export OPENSSL_CONF="${OPENSSL_PREFIX}/ssl/openssl-oqs.cnf"
export OPENSSL_MODULES="${OQSPROVIDER_MODULE_DIR}"
hash -r

echo
echo "Verification:"
which openssl
openssl version -a
ldd "$(command -v openssl)" | egrep 'ssl|crypto' || true
openssl list -providers
openssl list -signature-algorithms | grep -i mldsa || true
openssl list -signature-algorithms -provider default -provider oqsprovider | grep -Ei 'mldsa|dilithium' || true
openssl list -tls-groups | egrep 'MLKEM|X25519|P-256|P-384' || true

echo
echo "Done."
echo "In new shells run:"
echo "  source /etc/profile.d/oqs-client-env.sh"
echo
echo "Example:"
echo "  echo | openssl s_client -connect YOUR_SERVER_IP:8445 -servername localhost -tls1_3 -groups MLKEM768"
