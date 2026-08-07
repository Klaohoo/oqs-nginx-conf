#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

LIBOQS_PREFIX="/opt/liboqs"
OQSPROV_PREFIX="/opt/oqs-provider"
LIBOQS_SRC="/usr/local/src/liboqs"
OQSPROV_SRC="/usr/local/src/oqs-provider"

echo "[4/10] Building and installing oqs-provider"
git clone --depth 1 https://github.com/open-quantum-safe/oqs-provider.git "${OQSPROV_SRC}"

cmake -S "${OQSPROV_SRC}" -B "${OQSPROV_SRC}/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${OQSPROV_PREFIX}" \
  -DOQS_DIR="${LIBOQS_PREFIX}" \
  -DOPENSSL_ROOT_DIR=/usr

cmake --build "${OQSPROV_SRC}/build" -j"$(nproc)"
cmake --install "${OQSPROV_SRC}/build"

OQSPROVIDER_SO="$(find "${OQSPROV_PREFIX}" -type f -name 'oqsprovider.so' | head -n1)"
if [[ -z "${OQSPROVIDER_SO}" ]]; then
  echo "oqsprovider.so not found after install"
  exit 1
fi
OQSPROVIDER_MODULE_DIR="$(dirname "${OQSPROVIDER_SO}")"

echo "[5/10] Writing OpenSSL provider config"
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
Environment=LD_LIBRARY_PATH=${LIBOQS_PREFIX}/lib:${LIBOQS_PREFIX}/lib64
EOF

systemctl daemon-reload

export OPENSSL_CONF=/etc/ssl/openssl-oqs.cnf
export OPENSSL_MODULES="${OQSPROVIDER_MODULE_DIR}"
export LD_LIBRARY_PATH="${LIBOQS_PREFIX}/lib:${LIBOQS_PREFIX}/lib64:${LD_LIBRARY_PATH:-}"

echo "[6/10] Verifying provider load"
openssl list -providers

echo "[7/10] Detecting ML-DSA-65 algorithm name and hybrid ML-KEM group name"
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
  echo "Could not find a working ML-DSA-65 algorithm name in OpenSSL/oqs-provider"
  exit 1
fi

TLS_GROUP_LIST="$(openssl list -tls-groups 2>/dev/null || true)"
HYBRID_GROUP="X25519MLKEM768"
for cand in X25519MLKEM768 x25519_mlkem768 X25519+MLKEM768; do
  if grep -q "${cand}" <<<"${TLS_GROUP_LIST}"; then
    HYBRID_GROUP="${cand}"
    break
  fi
done

echo "Using ML-DSA algorithm: ${MLDSA_ALG}"
echo "Using hybrid TLS group: ${HYBRID_GROUP}"

echo "[8/10] Creating self-signed certificates"
install -d -m 755 /etc/nginx/certs

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

echo "[9/10] Creating demo web roots"
mkdir -p /var/www/pq-demo/{8443,8444,8445,8446}

cat >/var/www/pq-demo/8443/index.html <<EOF
<html><body><h1>8443</h1><p>RSA cert</p><p>Groups: X25519:P-256</p></body></html>
EOF

cat >/var/www/pq-demo/8444/index.html <<EOF
<html><body><h1>8444</h1><p>ECDSA cert</p><p>Groups: P-384:X25519</p></body></html>
EOF

cat >/var/www/pq-demo/8445/index.html <<EOF
<html><body><h1>8445</h1><p>ML-DSA-65 cert</p><p>Groups: ${HYBRID_GROUP}:X25519</p></body></html>
EOF

cat >/var/www/pq-demo/8446/index.html <<EOF
<html><body><h1>8446</h1><p>RSA cert</p><p>Groups: ${HYBRID_GROUP}:P-256</p></body></html>
EOF

echo "[10/10] Writing nginx config and starting service"
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

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

nginx -t
systemctl enable --now nginx
systemctl restart nginx

echo
echo "Done."
echo "Ports configured:"
echo "  8443 -> RSA cert + classical groups X25519:P-256"
echo "  8444 -> ECDSA cert + classical groups P-384:X25519"
echo "  8445 -> ML-DSA-65 cert + hybrid group ${HYBRID_GROUP}:X25519"
echo "  8446 -> RSA cert + hybrid group ${HYBRID_GROUP}:P-256"
echo
echo "Quick checks:"
echo "  openssl s_client -connect 127.0.0.1:8443 -tls1_3"
echo "  OPENSSL_CONF=/etc/ssl/openssl-oqs.cnf OPENSSL_MODULES=${OQSPROVIDER_MODULE_DIR} openssl s_client -connect 127.0.0.1:8445 -tls1_3 -provider default -provider oqsprovider"
