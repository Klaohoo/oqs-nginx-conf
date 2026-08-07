#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root"
  exit 1
fi

LIBOQS_PREFIX="/opt/liboqs"
OQSPROV_PREFIX="/opt/oqs-provider"
OQSPROV_SRC="/usr/local/src/oqs-provider"

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

export OPENSSL_CONF=/etc/ssl/openssl-oqs.cnf
export OPENSSL_MODULES="${OQSPROVIDER_MODULE_DIR}"
export LD_LIBRARY_PATH="${LIBOQS_PREFIX}/lib:${LIBOQS_PREFIX}/lib64:${LD_LIBRARY_PATH:-}"

echo "[8/10] Detecting ML-DSA algorithm and pure ML-KEM TLS group"

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
  echo "Try:"
  echo "  openssl list -signature-algorithms -provider default -provider oqsprovider"
  exit 1
fi

MLKEM_GROUP=""
for cand in MLKEM768 mlkem768 Kyber768 kyber768; do
  OUT="$(openssl s_client \
    -provider default \
    -provider oqsprovider \
    -groups "${cand}" \
    -connect 127.0.0.1:1 </dev/null 2>&1 || true)"

  if ! grep -Eqi 'SSL_CONF_cmd|unknown group|group.*unknown|error setting groups|bad value|no groups available|Call to SSL_CONF_cmd' <<<"${OUT}"; then
    MLKEM_GROUP="${cand}"
    break
  fi
done

if [[ -z "${MLKEM_GROUP}" ]]; then
  echo "Could not find a working pure ML-KEM TLS group name."
  echo
  echo "This usually means your current OpenSSL/libssl/nginx TLS stack does not expose PQ KEM groups."
  echo "If so, pure ML-KEM will not work in nginx on this build."
  echo
  echo "Manual probes you can try:"
  echo "  openssl s_client -provider default -provider oqsprovider -groups MLKEM768 -connect 127.0.0.1:1"
  echo "  openssl s_client -provider default -provider oqsprovider -groups mlkem768 -connect 127.0.0.1:1"
  echo "  openssl s_client -provider default -provider oqsprovider -groups Kyber768 -connect 127.0.0.1:1"
  exit 1
fi

echo "Using ML-DSA algorithm: ${MLDSA_ALG}"
echo "Using pure ML-KEM TLS group: ${MLKEM_GROUP}"

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
<html><body><h1>8445</h1><p>ML-DSA cert</p><p>Groups: ${MLKEM_GROUP}</p></body></html>
EOF

cat >/var/www/pq-demo/8446/index.html <<EOF
<html><body><h1>8446</h1><p>RSA cert</p><p>Groups: ${MLKEM_GROUP}</p></body></html>
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
    ssl_conf_command Groups ${MLKEM_GROUP};
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
    ssl_conf_command Groups ${MLKEM_GROUP};
}
EOF

ln -sf /etc/nginx/sites-available/pq-demo.conf /etc/nginx/sites-enabled/pq-demo.conf

nginx -t
systemctl restart nginx

echo
echo "Done."
echo "Configured:"
echo "  8443 -> RSA cert + X25519:P-256"
echo "  8444 -> ECDSA cert + P-384:X25519"
echo "  8445 -> ML-DSA cert + ${MLKEM_GROUP}"
echo "  8446 -> RSA cert + ${MLKEM_GROUP}"
