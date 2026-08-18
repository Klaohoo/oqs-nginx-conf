#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

OPENSSL_VER="3.5.1"
NGINX_VER="1.28.0"

OPENSSL_PREFIX="/opt/openssl-3.5"
LIBOQS_PREFIX="/opt/liboqs"
OQSPROV_PREFIX="/opt/oqs-provider"
NGINX_PREFIX="/opt/nginx-oqs"

SRC_ROOT="/usr/local/src"
OPENSSL_SRC="${SRC_ROOT}/openssl-${OPENSSL_VER}"
LIBOQS_SRC="${SRC_ROOT}/liboqs"
OQSPROV_SRC="${SRC_ROOT}/oqs-provider"
NGINX_SRC="${SRC_ROOT}/nginx-${NGINX_VER}"

case "$(uname -m)" in
  x86_64) OPENSSL_TARGET="linux-x86_64" ;;
  aarch64|arm64) OPENSSL_TARGET="linux-aarch64" ;;
  *)
    echo "Unsupported architecture: $(uname -m)"
    exit 1
    ;;
esac

echo "[1/12] Stopping any old nginx instances"
systemctl disable --now nginx 2>/dev/null || true
systemctl disable --now nginx-oqs 2>/dev/null || true
pkill -f "${NGINX_PREFIX}/sbin/nginx" 2>/dev/null || true

echo "[2/12] Installing build dependencies"
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
  libpcre3-dev \
  libpcre2-dev \
  tar

echo "[3/12] Removing old custom install trees"
rm -rf \
  "${OPENSSL_PREFIX}" \
  "${LIBOQS_PREFIX}" \
  "${OQSPROV_PREFIX}" \
  "${NGINX_PREFIX}" \
  "${OPENSSL_SRC}" \
  "${LIBOQS_SRC}" \
  "${OQSPROV_SRC}" \
  "${NGINX_SRC}"

mkdir -p "${SRC_ROOT}"

echo "[4/12] Building OpenSSL ${OPENSSL_VER}"
cd "${SRC_ROOT}"
rm -f "openssl-${OPENSSL_VER}.tar.gz"
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

if [[ -d "${OPENSSL_PREFIX}/lib64" ]]; then
  OPENSSL_LIBDIR="${OPENSSL_PREFIX}/lib64"
else
  OPENSSL_LIBDIR="${OPENSSL_PREFIX}/lib"
fi

printf '%s\n' "${OPENSSL_LIBDIR}" >/etc/ld.so.conf.d/openssl-3.5.conf
ldconfig

export PATH="${OPENSSL_PREFIX}/bin:${PATH}"
export LD_LIBRARY_PATH="${OPENSSL_LIBDIR}:${LD_LIBRARY_PATH:-}"
hash -r

echo "[5/12] Building liboqs"
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

echo "[6/12] Building oqs-provider"
unset OPENSSL_CONF
unset OPENSSL_MODULES

git clone --depth 1 https://github.com/open-quantum-safe/oqs-provider.git "${OQSPROV_SRC}"

export PKG_CONFIG_PATH="${OPENSSL_LIBDIR}/pkgconfig:${LIBOQS_PREFIX}/lib/pkgconfig:${LIBOQS_PREFIX}/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"

OPENSSL_SSL_LIBRARY="${OPENSSL_LIBDIR}/libssl.so"
OPENSSL_CRYPTO_LIBRARY="${OPENSSL_LIBDIR}/libcrypto.so"

if [[ ! -f "${OPENSSL_SSL_LIBRARY}" && -f "${OPENSSL_LIBDIR}/libssl.so.3" ]]; then
  OPENSSL_SSL_LIBRARY="${OPENSSL_LIBDIR}/libssl.so.3"
fi

if [[ ! -f "${OPENSSL_CRYPTO_LIBRARY}" && -f "${OPENSSL_LIBDIR}/libcrypto.so.3" ]]; then
  OPENSSL_CRYPTO_LIBRARY="${OPENSSL_LIBDIR}/libcrypto.so.3"
fi

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
  echo "Could not find oqsprovider.so"
  exit 1
fi

OQSPROVIDER_MODULE_DIR="$(dirname "${OQSPROVIDER_SO}")"

echo "[7/12] Writing OpenSSL OQS config"
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

cat >/etc/profile.d/oqs-server-env.sh <<EOF
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

echo "[8/12] Verifying OpenSSL/OQS stack"
which openssl
openssl version -a
ldd "$(command -v openssl)" | egrep 'ssl|crypto' || true
openssl list -providers
openssl list -signature-algorithms | grep -i 'ML-DSA' >/dev/null
openssl list -tls-groups | egrep 'MLKEM512|MLKEM768|MLKEM1024|X25519|P-256|P-384' >/dev/null

echo "[9/12] Building nginx ${NGINX_VER}"
cd "${SRC_ROOT}"
rm -f "nginx-${NGINX_VER}.tar.gz"
curl -LO "https://nginx.org/download/nginx-${NGINX_VER}.tar.gz"
tar xf "nginx-${NGINX_VER}.tar.gz"

cd "${NGINX_SRC}"
./configure \
  --prefix="${NGINX_PREFIX}" \
  --sbin-path="${NGINX_PREFIX}/sbin/nginx" \
  --conf-path="${NGINX_PREFIX}/conf/nginx.conf" \
  --pid-path="${NGINX_PREFIX}/logs/nginx.pid" \
  --error-log-path="${NGINX_PREFIX}/logs/error.log" \
  --http-log-path="${NGINX_PREFIX}/logs/access.log" \
  --with-http_ssl_module \
  --with-http_v2_module \
  --with-stream \
  --with-stream_ssl_module \
  --with-cc-opt="-I${OPENSSL_PREFIX}/include" \
  --with-ld-opt="-Wl,-rpath,${OPENSSL_LIBDIR} -L${OPENSSL_LIBDIR}"

make -j"$(nproc)"
make install

echo "[10/12] Generating certificates and content"
mkdir -p "${NGINX_PREFIX}/certs"
mkdir -p "${NGINX_PREFIX}/html"/{8443,8444,8445,8446,8447,8448,8449}

cat >"${NGINX_PREFIX}/certs/req.cnf" <<'EOF'
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

openssl genpkey -algorithm RSA \
  -pkeyopt rsa_keygen_bits:3072 \
  -out "${NGINX_PREFIX}/certs/rsa.key"

openssl req -new -x509 \
  -key "${NGINX_PREFIX}/certs/rsa.key" \
  -out "${NGINX_PREFIX}/certs/rsa.crt" \
  -days 365 \
  -config "${NGINX_PREFIX}/certs/req.cnf"

openssl genpkey -algorithm EC \
  -pkeyopt group:prime256v1 \
  -out "${NGINX_PREFIX}/certs/ecdsa.key"

openssl req -new -x509 \
  -key "${NGINX_PREFIX}/certs/ecdsa.key" \
  -out "${NGINX_PREFIX}/certs/ecdsa.crt" \
  -days 365 \
  -config "${NGINX_PREFIX}/certs/req.cnf"

openssl genpkey -algorithm ML-DSA-44 \
  -out "${NGINX_PREFIX}/certs/mldsa44.key"

openssl req -new -x509 \
  -key "${NGINX_PREFIX}/certs/mldsa44.key" \
  -out "${NGINX_PREFIX}/certs/mldsa44.crt" \
  -days 365 \
  -config "${NGINX_PREFIX}/certs/req.cnf"

openssl genpkey -algorithm ML-DSA-65 \
  -out "${NGINX_PREFIX}/certs/mldsa65.key"

openssl req -new -x509 \
  -key "${NGINX_PREFIX}/certs/mldsa65.key" \
  -out "${NGINX_PREFIX}/certs/mldsa65.crt" \
  -days 365 \
  -config "${NGINX_PREFIX}/certs/req.cnf"

openssl genpkey -algorithm ML-DSA-87 \
  -out "${NGINX_PREFIX}/certs/mldsa87.key"

openssl req -new -x509 \
  -key "${NGINX_PREFIX}/certs/mldsa87.key" \
  -out "${NGINX_PREFIX}/certs/mldsa87.crt" \
  -days 365 \
  -config "${NGINX_PREFIX}/certs/req.cnf"

chmod 600 "${NGINX_PREFIX}/certs/"*.key

cat >"${NGINX_PREFIX}/html/8443/index.html" <<'EOF'
<html><body><h1>8443</h1><p>RSA cert</p><p>Groups: X25519:P-256</p></body></html>
EOF

cat >"${NGINX_PREFIX}/html/8444/index.html" <<'EOF'
<html><body><h1>8444</h1><p>ECDSA cert</p><p>Groups: P-384:X25519</p></body></html>
EOF

cat >"${NGINX_PREFIX}/html/8445/index.html" <<'EOF'
<html><body><h1>8445</h1><p>ML-DSA-65 cert</p><p>Groups: MLKEM768</p></body></html>
EOF

cat >"${NGINX_PREFIX}/html/8446/index.html" <<'EOF'
<html><body><h1>8446</h1><p>RSA cert</p><p>Groups: MLKEM768</p></body></html>
EOF

cat >"${NGINX_PREFIX}/html/8447/index.html" <<'EOF'
<html><body><h1>8447</h1><p>ML-DSA-65 cert</p><p>Groups: X25519:P-256</p></body></html>
EOF

cat >"${NGINX_PREFIX}/html/8448/index.html" <<'EOF'
<html><body><h1>8448</h1><p>ML-DSA-44 cert</p><p>Groups: MLKEM512</p></body></html>
EOF

cat >"${NGINX_PREFIX}/html/8449/index.html" <<'EOF'
<html><body><h1>8449</h1><p>ML-DSA-87 cert</p><p>Groups: MLKEM1024</p></body></html>
EOF

echo "[11/12] Writing nginx config"
cat >"${NGINX_PREFIX}/conf/nginx.conf" <<EOF
worker_processes auto;
pid logs/nginx.pid;

events {
    worker_connections 1024;
}

http {
    default_type text/html;
    sendfile on;
    keepalive_timeout 65;

    server {
        listen 8443 ssl;
        server_name localhost;
        root ${NGINX_PREFIX}/html/8443;
        index index.html;

        ssl_protocols TLSv1.3;
        ssl_certificate ${NGINX_PREFIX}/certs/rsa.crt;
        ssl_certificate_key ${NGINX_PREFIX}/certs/rsa.key;
        ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256;
        ssl_conf_command Groups X25519:P-256;
    }

    server {
        listen 8444 ssl;
        server_name localhost;
        root ${NGINX_PREFIX}/html/8444;
        index index.html;

        ssl_protocols TLSv1.3;
        ssl_certificate ${NGINX_PREFIX}/certs/ecdsa.crt;
        ssl_certificate_key ${NGINX_PREFIX}/certs/ecdsa.key;
        ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256;
        ssl_conf_command Groups P-384:X25519;
    }

    server {
        listen 8445 ssl;
        server_name localhost;
        root ${NGINX_PREFIX}/html/8445;
        index index.html;

        ssl_protocols TLSv1.3;
        ssl_certificate ${NGINX_PREFIX}/certs/mldsa65.crt;
        ssl_certificate_key ${NGINX_PREFIX}/certs/mldsa65.key;
        ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256;
        ssl_conf_command Groups MLKEM768;
    }

    server {
        listen 8446 ssl;
        server_name localhost;
        root ${NGINX_PREFIX}/html/8446;
        index index.html;

        ssl_protocols TLSv1.3;
        ssl_certificate ${NGINX_PREFIX}/certs/rsa.crt;
        ssl_certificate_key ${NGINX_PREFIX}/certs/rsa.key;
        ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256;
        ssl_conf_command Groups MLKEM768;
    }

    server {
        listen 8447 ssl;
        server_name localhost;
        root ${NGINX_PREFIX}/html/8447;
        index index.html;

        ssl_protocols TLSv1.3;
        ssl_certificate ${NGINX_PREFIX}/certs/mldsa65.crt;
        ssl_certificate_key ${NGINX_PREFIX}/certs/mldsa65.key;
        ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256;
        ssl_conf_command Groups X25519:P-256;
    }

    server {
        listen 8448 ssl;
        server_name localhost;
        root ${NGINX_PREFIX}/html/8448;
        index index.html;

        ssl_protocols TLSv1.3;
        ssl_certificate ${NGINX_PREFIX}/certs/mldsa44.crt;
        ssl_certificate_key ${NGINX_PREFIX}/certs/mldsa44.key;
        ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256;
        ssl_conf_command Groups MLKEM512;
    }

    server {
        listen 8449 ssl;
        server_name localhost;
        root ${NGINX_PREFIX}/html/8449;
        index index.html;

        ssl_protocols TLSv1.3;
        ssl_certificate ${NGINX_PREFIX}/certs/mldsa87.crt;
        ssl_certificate_key ${NGINX_PREFIX}/certs/mldsa87.key;
        ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256;
        ssl_conf_command Groups MLKEM1024;
    }
}
EOF

echo "[12/12] Installing systemd service and starting nginx"
cat >/etc/systemd/system/nginx-oqs.service <<EOF
[Unit]
Description=Custom nginx linked against OpenSSL 3.5 + OQS
After=network.target

[Service]
Type=forking
PIDFile=${NGINX_PREFIX}/logs/nginx.pid
Environment=OPENSSL_CONF=${OPENSSL_PREFIX}/ssl/openssl-oqs.cnf
Environment=OPENSSL_MODULES=${OQSPROVIDER_MODULE_DIR}
Environment=LD_LIBRARY_PATH=${OPENSSL_LIBDIR}:${LIBOQS_PREFIX}/lib:${LIBOQS_PREFIX}/lib64
ExecStartPre=${NGINX_PREFIX}/sbin/nginx -t -c ${NGINX_PREFIX}/conf/nginx.conf
ExecStart=${NGINX_PREFIX}/sbin/nginx -c ${NGINX_PREFIX}/conf/nginx.conf
ExecReload=/bin/kill -s HUP \$MAINPID
ExecStop=/bin/kill -s QUIT \$MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

env \
  OPENSSL_CONF="${OPENSSL_PREFIX}/ssl/openssl-oqs.cnf" \
  OPENSSL_MODULES="${OQSPROVIDER_MODULE_DIR}" \
  LD_LIBRARY_PATH="${OPENSSL_LIBDIR}:${LIBOQS_PREFIX}/lib:${LIBOQS_PREFIX}/lib64" \
  "${NGINX_PREFIX}/sbin/nginx" -t -c "${NGINX_PREFIX}/conf/nginx.conf"

systemctl enable --now nginx-oqs.service

echo
echo "Rebuild complete."
echo
echo "Environment file:"
echo "  source /etc/profile.d/oqs-server-env.sh"
echo
echo "Useful checks:"
echo "  source /etc/profile.d/oqs-server-env.sh"
echo "  which openssl"
echo "  openssl version -a"
echo "  openssl list -providers"
echo "  openssl list -signature-algorithms | grep -i mldsa"
echo "  openssl list -tls-groups | egrep 'MLKEM|X25519|P-256|P-384'"
echo "  ldd ${NGINX_PREFIX}/sbin/nginx | egrep 'ssl|crypto'"
echo "  systemctl status nginx-oqs --no-pager -l"
echo
echo "Configured ports:"
echo "  8443 -> RSA + X25519:P-256"
echo "  8444 -> ECDSA + P-384:X25519"
echo "  8445 -> ML-DSA-65 + MLKEM768"
echo "  8446 -> RSA + MLKEM768"
echo "  8447 -> ML-DSA-65 + X25519:P-256"
echo "  8448 -> ML-DSA-44 + MLKEM512"
echo "  8449 -> ML-DSA-87 + MLKEM1024"
After it finishes, I recommend these checks:

source /etc/profile.d/oqs-server-env.sh
which openssl
openssl version -a
openssl list -providers
openssl list -signature-algorithms | grep -i mldsa
openssl list -tls-groups | egrep 'MLKEM|X25519|P-256|P-384'
ldd /opt/nginx-oqs/sbin/nginx | egrep 'ssl|crypto'
systemctl status nginx-oqs --no-pager -l
