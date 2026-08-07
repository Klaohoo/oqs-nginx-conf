#!/usr/bin/env bash
set -euo pipefail

OPENSSL_PREFIX="/opt/openssl-3.5"
LIBOQS_PREFIX="/opt/liboqs"
OQSPROV_PREFIX="/opt/oqs-provider"
NGINX_PREFIX="/opt/nginx-oqs"

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

hash -r

echo "Checking supported ML-DSA algorithms"
openssl list -signature-algorithms | egrep 'ML-DSA-44|ML-DSA-65|ML-DSA-87' || true

echo "Checking supported TLS groups"
openssl list -tls-groups | egrep 'MLKEM512|MLKEM768|MLKEM1024|X25519|P-256|P-384' || true

mkdir -p "${NGINX_PREFIX}/certs"
mkdir -p "${NGINX_PREFIX}/html"/{8447,8448,8449}

if [[ ! -f "${NGINX_PREFIX}/certs/req.cnf" ]]; then
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
fi

echo "Generating ML-DSA-44 certificate"
openssl genpkey -algorithm ML-DSA-44 \
  -out "${NGINX_PREFIX}/certs/mldsa44.key"

openssl req -new -x509 \
  -key "${NGINX_PREFIX}/certs/mldsa44.key" \
  -out "${NGINX_PREFIX}/certs/mldsa44.crt" \
  -days 365 \
  -config "${NGINX_PREFIX}/certs/req.cnf"

echo "Generating ML-DSA-87 certificate"
openssl genpkey -algorithm ML-DSA-87 \
  -out "${NGINX_PREFIX}/certs/mldsa87.key"

openssl req -new -x509 \
  -key "${NGINX_PREFIX}/certs/mldsa87.key" \
  -out "${NGINX_PREFIX}/certs/mldsa87.crt" \
  -days 365 \
  -config "${NGINX_PREFIX}/certs/req.cnf"

chmod 600 "${NGINX_PREFIX}/certs/"*.key

cat >"${NGINX_PREFIX}/html/8447/index.html" <<'EOF'
<html><body><h1>8447</h1><p>ML-DSA-65 cert</p><p>Groups: X25519:P-256</p></body></html>
EOF

cat >"${NGINX_PREFIX}/html/8448/index.html" <<'EOF'
<html><body><h1>8448</h1><p>ML-DSA-44 cert</p><p>Groups: MLKEM512</p></body></html>
EOF

cat >"${NGINX_PREFIX}/html/8449/index.html" <<'EOF'
<html><body><h1>8449</h1><p>ML-DSA-87 cert</p><p>Groups: MLKEM1024</p></body></html>
EOF

echo
echo "Done generating new certs and content."
echo "New certs:"
echo "  ${NGINX_PREFIX}/certs/mldsa44.crt"
echo "  ${NGINX_PREFIX}/certs/mldsa87.crt"
