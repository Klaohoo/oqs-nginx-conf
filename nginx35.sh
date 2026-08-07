#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

OPENSSL_PREFIX="/opt/openssl-3.5"
LIBOQS_PREFIX="/opt/liboqs"
OQSPROV_PREFIX="/opt/oqs-provider"
NGINX_VER="1.28.0"
NGINX_PREFIX="/opt/nginx-oqs"
SRC_ROOT="/usr/local/src"
NGINX_SRC="${SRC_ROOT}/nginx-${NGINX_VER}"

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
OQSPROVIDER_MODULE_DIR="$(dirname "${OQSPROVIDER_SO}")"

export PATH="${OPENSSL_PREFIX}/bin:${PATH}"
export LD_LIBRARY_PATH="${OPENSSL_LIBDIR}:${LIBOQS_PREFIX}/lib:${LIBOQS_PREFIX}/lib64:${LD_LIBRARY_PATH:-}"
export OPENSSL_CONF="${OPENSSL_PREFIX}/ssl/openssl-oqs.cnf"
export OPENSSL_MODULES="${OQSPROVIDER_MODULE_DIR}"

hash -r

echo "[1/9] Verifying OpenSSL stack"
which openssl
openssl version -a
ldd "$(command -v openssl)" | egrep 'ssl|crypto' || true

echo "[2/9] Detecting ML-KEM TLS group"
TLS_GROUPS="$(openssl list -tls-groups 2>/dev/null || true)"
MLKEM_GROUP=""
for cand in MLKEM768 mlkem768; do
  if grep -qw "${cand}" <<<"${TLS_GROUPS}"; then
    MLKEM_GROUP="${cand}"
    break
  fi
done

if [[ -z "${MLKEM_GROUP}" ]]; then
  echo "Pure ML-KEM TLS group not found in this OpenSSL build."
  echo "Available groups:"
  echo "${TLS_GROUPS}"
  exit 1
fi

echo "Using ML-KEM group: ${MLKEM_GROUP}"

echo "[3/9] Installing nginx build dependencies"
apt-get update
apt-get install -y build-essential curl ca-certificates zlib1g-dev libpcre3-dev libpcre2-dev

echo "[4/9] Building nginx against ${OPENSSL_PREFIX}"
rm -rf "${NGINX_SRC}"
mkdir -p "${SRC_ROOT}"
cd "${SRC_ROOT}"
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

echo "[5/9] Verifying nginx linkage"
ldd "${NGINX_PREFIX}/sbin/nginx" | egrep 'ssl|crypto' || true

echo "[6/9] Creating certs"
mkdir -p "${NGINX_PREFIX}/certs" "${NGINX_PREFIX}/html"/{8443,8444,8445,8446}

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

openssl ecparam -name prime256v1 -genkey -noout \
  -out "${NGINX_PREFIX}/certs/ecdsa.key"

openssl req -new -x509 \
  -key "${NGINX_PREFIX}/certs/ecdsa.key" \
  -out "${NGINX_PREFIX}/certs/ecdsa.crt" \
  -days 365 \
  -config "${NGINX_PREFIX}/certs/req.cnf"

openssl genpkey -algorithm ML-DSA-65 \
  -out "${NGINX_PREFIX}/certs/mldsa65.key"

openssl req -new -x509 \
  -key "${NGINX_PREFIX}/certs/mldsa65.key" \
  -out "${NGINX_PREFIX}/certs/mldsa65.crt" \
  -days 365 \
  -config "${NGINX_PREFIX}/certs/req.cnf"

chmod 600 "${NGINX_PREFIX}/certs/"*.key

echo "[7/9] Writing test pages"
cat >"${NGINX_PREFIX}/html/8443/index.html" <<EOF
<html><body><h1>8443</h1><p>RSA cert</p><p>Groups: X25519:P-256</p></body></html>
EOF

cat >"${NGINX_PREFIX}/html/8444/index.html" <<EOF
<html><body><h1>8444</h1><p>ECDSA cert</p><p>Groups: P-384:X25519</p></body></html>
EOF

cat >"${NGINX_PREFIX}/html/8445/index.html" <<EOF
<html><body><h1>8445</h1><p>ML-DSA cert</p><p>Groups: ${MLKEM_GROUP}</p></body></html>
EOF

cat >"${NGINX_PREFIX}/html/8446/index.html" <<EOF
<html><body><h1>8446</h1><p>RSA cert</p><p>Groups: ${MLKEM_GROUP}</p></body></html>
EOF

echo "[8/9] Writing nginx config"
cat >"${NGINX_PREFIX}/conf/nginx.conf" <<EOF
worker_processes auto;
pid logs/nginx.pid;

events {
    worker_connections 1024;
}

http {
    default_type application/octet-stream;
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
        ssl_conf_command Groups ${MLKEM_GROUP};
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
        ssl_conf_command Groups ${MLKEM_GROUP};
    }
}
EOF

echo "[9/9] Creating systemd service and starting nginx"
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
"${NGINX_PREFIX}/sbin/nginx" -t -c "${NGINX_PREFIX}/conf/nginx.conf"
systemctl enable --now nginx-oqs.service

echo
echo "Done."
echo "nginx binary: ${NGINX_PREFIX}/sbin/nginx"
echo "config:        ${NGINX_PREFIX}/conf/nginx.conf"
echo "service:       nginx-oqs.service"
echo "ML-KEM group:  ${MLKEM_GROUP}"
echo
echo "Check status:"
echo "  systemctl status nginx-oqs --no-pager -l"
echo
echo "If nginx is already running from apt, stop it:"
echo "  systemctl disable --now nginx"
