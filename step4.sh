#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

OQSPROV_PREFIX="/opt/oqs-provider"
OQSPROV_SRC="/usr/local/src/oqs-provider"

echo "[4/10] Detecting existing liboqs install"
LIBOQS_PREFIX=""
for p in /opt/liboqs /usr/local /usr; do
  if [[ -e "${p}/lib/liboqs.so" || -e "${p}/lib64/liboqs.so" || -e "${p}/lib/liboqs.so.0" || -e "${p}/lib64/liboqs.so.0" ]]; then
    LIBOQS_PREFIX="${p}"
    break
  fi
done

if [[ -z "${LIBOQS_PREFIX}" ]]; then
  echo "Could not find an existing liboqs installation."
  echo "Finish steps 1-3 first, or set LIBOQS_PREFIX manually in this script."
  exit 1
fi

echo "Using liboqs prefix: ${LIBOQS_PREFIX}"

LIBOQS_LIBDIRS=()
[[ -d "${LIBOQS_PREFIX}/lib" ]] && LIBOQS_LIBDIRS+=("${LIBOQS_PREFIX}/lib")
[[ -d "${LIBOQS_PREFIX}/lib64" ]] && LIBOQS_LIBDIRS+=("${LIBOQS_PREFIX}/lib64")

if [[ "${#LIBOQS_LIBDIRS[@]}" -eq 0 ]]; then
  echo "Could not find lib or lib64 under ${LIBOQS_PREFIX}"
  exit 1
fi

LIBOQS_LD_PATH="$(IFS=:; echo "${LIBOQS_LIBDIRS[*]}")"

printf '%s\n' "${LIBOQS_LIBDIRS[@]}" >/etc/ld.so.conf.d/liboqs.conf
ldconfig

echo "[5/10] Building and installing oqs-provider"
rm -rf "${OQSPROV_SRC}"
git clone --depth 1 https://github.com/open-quantum-safe/oqs-provider.git "${OQSPROV_SRC}"

cmake -S "${OQSPROV_SRC}" -B "${OQSPROV_SRC}/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${OQSPROV_PREFIX}" \
  -DOQS_DIR="${LIBOQS_PREFIX}" \
  -DOPENSSL_ROOT_DIR=/usr

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
  echo "oqsprovider.so not found"
  exit 1
fi

OQSPROVIDER_MODULE_DIR="$(dirname "${OQSPROVIDER_SO}")"

echo "Using oqsprovider.so at: ${OQSPROVIDER_SO}"
echo "Using OpenSSL module dir: ${OQSPROVIDER_MODULE_DIR}"

echo "[6/10] Writing OpenSSL provider config"
mkdir -p /etc/ssl
cat >/etc/ssl/openssl-oqs.cnf <<EOF
config_diagnostics = 1
openssl_conf = openssl_init

[openssl_init]
providers = provider_sect

[provider_sect]
default = default_sect
oqsprovider = oqsprovider_sect

[default_sect]
activate = 1

[oqsprovider_sect]
activate = 1
module = ${OQSPROVIDER_SO}
EOF

mkdir -p /etc/systemd/system/nginx.service.d
cat >/etc/systemd/system/nginx.service.d/oqs.conf <<EOF
[Service]
Environment=OPENSSL_CONF=/etc/ssl/openssl-oqs.cnf
Environment=OPENSSL_MODULES=${OQSPROVIDER_MODULE_DIR}
Environment=LD_LIBRARY_PATH=${LIBOQS_LD_PATH}
EOF

systemctl daemon-reload

export OPENSSL_CONF=/etc/ssl/openssl-oqs.cnf
export OPENSSL_MODULES="${OQSPROVIDER_MODULE_DIR}"
export LD_LIBRARY_PATH="${LIBOQS_LD_PATH}:${LD_LIBRARY_PATH:-}"

echo "[7/10] Verifying provider load"
openssl list -providers

echo "[8/10] Detecting ML-DSA algorithm name and ML-KEM hybrid group name"
MLDSA_ALG=""
for cand in ML-DSA-65 mldsa65 MLDSA65; do
  rm -f /tmp/mldsa-probe.key
  if openssl genpkey -provider default -provider oqsprovider -algorithm "${cand}" -out /tmp/mldsa-probe.key >/dev/null 2>&1; then
    MLDSA_ALG="${cand}"
    rm -f /tmp/mldsa-probe.key
    break
  fi
done

if [[ -z "${MLDSA_ALG}" ]]; then
  echo "Could not find a working ML-DSA-65 algorithm name."
  echo "Available signature algorithms:"
  openssl list -signature-algorithms -provider default -provider oqsprovider || true
  exit 1
fi

TLS_GROUP_LIST="$(openssl list -tls-groups 2>/dev/null || true)"
HYBRID_GROUP=""
for cand in X25519MLKEM768 x25519_mlkem768 X25519+MLKEM768; do
  if grep -q "${cand}" <<<"${TLS_GROUP_LIST}"; then
    HYBRID_GROUP="${cand}"
    break
  fi
done

if [[ -z "${HYBRID_GROUP}" ]]; then
  echo "Could not find a working hybrid ML-KEM TLS group name."
  echo "Available TLS groups:"
  openssl list -tls-groups || true
  exit 1
fi

echo "Using ML-DSA algorithm: ${MLDSA_ALG}"
echo "Using hybrid TLS group: ${HYBRID_GROUP}"

echo "[9/10] Creating self-signed certificates"
mkdir -p /etc/nginx/certs

cat >/etc/nginx/certs/req.cnf <<'EOF'
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
  -out /etc/nginx/certs/rsa.key

openssl req -new -x509 \
  -key /etc/nginx/certs/rsa.key \
  -out /etc/nginx/certs/rsa.crt \
  -days 825 \
  -config /etc/nginx/certs/req.cnf

openssl ecparam -name prime256v1 -genkey -noout \
  -out /etc/nginx/certs/ecdsa.key

openssl req -new -x509 \
  -key /etc/nginx/certs/ecdsa.key \
  -out /etc/nginx/certs/ecdsa.crt \
  -days 825 \
  -config /etc/nginx/certs/req.cnf

openssl genpkey \
  -provider default \
  -provider oqsprovider \
  -algorithm "${MLDSA_ALG}" \
  -out /etc/nginx/certs/mldsa65.key

openssl req -new -x509 \
  -provider default \
  -provider oqsprovider \
  -key /etc/nginx/certs/mldsa65.key \
  -out /etc/nginx/certs/mldsa65.crt \
  -days 825 \
  -config /etc/nginx/certs/req.cnf

chmod 600 /etc/nginx/certs/*.key

echo "[10/10] Creating web roots and nginx config"
mkdir -p /var/www/pq-demo/{8443,8444,8445,8446}

cat >/var/www/pq-demo/8443/index.html <<EOF
<html><body><h1>8443</h1><p>RSA cert</p><p>Groups: X25519:P-256</p></body></html>
EOF

cat >/var/www/pq-demo/8444/index.html <<EOF
<html><body><h1>8444</h1><p>ECDSA cert</p><p>Groups: P-384:X25519</p></body></html>
EOF

cat >/var/www/pq-demo/8445/index.html <<EOF
<html><body><h1>8445</h1><p>ML-DSA cert</p><p>Groups: ${HYBRID_GROUP}:X25519</p></body></html>
EOF

cat >/var/www/pq-demo/8446/index.html <<EOF
<html><body><h1>8446</h1><p>RSA cert</p><p>Groups: ${HYBRID_GROUP}:P-256</p></body></html>
EOF

mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/pq-demo.conf

cat >/etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    sendfile on;
    keepalive_timeout 65;

    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log;

    include /etc/nginx/sites-enabled/*.conf;
}
EOF

cat >/etc/nginx/sites-available/pq-demo.conf <<EOF
server {
    listen 8443 ssl;
    listen [::]:8443 ssl;
    server_name _;
    root /var/www/pq-demo/8443;
    index index.html;

    ssl_protocols TLSv1.3;
    ssl_certificate /etc/nginx/certs/rsa.crt;
    ssl_certificate_key /etc/nginx/certs/rsa.key;
    ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256;
    ssl_conf_command Groups X25519:P-256;
}

server {
    listen 8444 ssl;
    listen [::]:8444 ssl;
    server_name _;
    root /var/www/pq-demo/8444;
    index index.html;

    ssl_protocols TLSv1.3;
    ssl_certificate /etc/nginx/certs/ecdsa.crt;
    ssl_certificate_key /etc/nginx/certs/ecdsa.key;
    ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256;
    ssl_conf_command Groups P-384:X25519;
}

server {
    listen 8445 ssl;
    listen [::]:8445 ssl;
    server_name _;
    root /var/www/pq-demo/8445;
    index index.html;

    ssl_protocols TLSv1.3;
    ssl_certificate /etc/nginx/certs/mldsa65.crt;
    ssl_certificate_key /etc/nginx/certs/mldsa65.key;
    ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256;
    ssl_conf_command Groups ${HYBRID_GROUP}:X25519;
}

server {
    listen 8446 ssl;
    listen [::]:8446 ssl;
    server_name _;
    root /var/www/pq-demo/8446;
    index index.html;

    ssl_protocols TLSv1.3;
    ssl_certificate /etc/nginx/certs/rsa.crt;
    ssl_certificate_key /etc/nginx/certs/rsa.key;
    ssl_conf_command Ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256;
    ssl_conf_command Groups ${HYBRID_GROUP}:P-256;
}
EOF

ln -sf /etc/nginx/sites-available/pq-demo.conf /etc/nginx/sites-enabled/pq-demo.conf

systemctl enable nginx || true
nginx -t
systemctl restart nginx

echo
echo "Done."
echo "Ports configured:"
echo "  8443 -> RSA cert + classical groups X25519:P-256"
echo "  8444 -> ECDSA cert + classical groups P-384:X25519"
echo "  8445 -> ML-DSA cert + hybrid group ${HYBRID_GROUP}:X25519"
echo "  8446 -> RSA cert + hybrid group ${HYBRID_GROUP}:P-256"
echo
echo "Verification commands:"
echo "  openssl list -providers"
echo "  openssl list -tls-groups"
echo "  nginx -t"
echo "  systemctl status nginx --no-pager -l"
