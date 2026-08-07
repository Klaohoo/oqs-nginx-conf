#!/usr/bin/env bash
set -euo pipefail

CERT_BASE="/etc/nginx/certs"
PQSIG="${PQSIG:-MLDSA65}"

RSA_DIR="$CERT_BASE/rsa"
ECDSA_DIR="$CERT_BASE/ecdsa"
PQ_DIR="$CERT_BASE/pq"

echo "[*] Creating certificate directories..."
mkdir -p "$RSA_DIR" "$ECDSA_DIR" "$PQ_DIR"
chmod 700 "$RSA_DIR" "$ECDSA_DIR" "$PQ_DIR"

echo "[*] Generating RSA private key..."
openssl genpkey \
  -algorithm RSA \
  -pkeyopt rsa_keygen_bits:3072 \
  -out "$RSA_DIR/server-rsa.key"

echo "[*] Generating RSA self-signed certificate..."
openssl req -new -x509 \
  -key "$RSA_DIR/server-rsa.key" \
  -out "$RSA_DIR/server-rsa.crt" \
  -days 3650 \
  -sha256 \
  -subj "/CN=classical-rsa.local" \
  -addext "subjectAltName=DNS:classical-rsa.local,DNS:hybrid-rsa.local,DNS:pqc-rsa.local"

echo "[*] Generating PQ private key using algorithm: $PQSIG"
openssl genpkey \
  -provider default \
  -provider oqsprovider \
  -algorithm "$PQSIG" \
  -out "$PQ_DIR/server-pq.key"

echo "[*] Generating PQ self-signed certificate..."
openssl req -new -x509 \
  -provider default \
  -provider oqsprovider \
  -key "$PQ_DIR/server-pq.key" \
  -out "$PQ_DIR/server-pq.crt" \
  -days 3650 \
  -subj "/CN=hybrid-pqcert.local" \
  -addext "subjectAltName=DNS:hybrid-pqcert.local,DNS:pqc-pqcert.local"

echo "[*] Generating ECDSA private key..."
openssl genpkey \
  -algorithm EC \
  -pkeyopt ec_paramgen_curve:P-256 \
  -pkeyopt ec_param_enc:named_curve \
  -out "$ECDSA_DIR/server-ecdsa.key"

echo "[*] Generating ECDSA self-signed certificate..."
openssl req -new -x509 \
  -key "$ECDSA_DIR/server-ecdsa.key" \
  -out "$ECDSA_DIR/server-ecdsa.crt" \
  -days 3650 \
  -sha256 \
  -subj "/CN=classical-ecdsa.local" \
  -addext "subjectAltName=DNS:classical-ecdsa.local,DNS:hybrid-ecdsa.local,DNS:pqc-ecdsa.local"

echo "[*] Setting file permissions..."
chmod 600 \
  "$RSA_DIR/server-rsa.key" \
  "$ECDSA_DIR/server-ecdsa.key" \
  "$PQ_DIR/server-pq.key"

chmod 644 \
  "$RSA_DIR/server-rsa.crt" \
  "$ECDSA_DIR/server-ecdsa.crt" \
  "$PQ_DIR/server-pq.crt"

echo "[*] Certificate generation complete."
echo
echo "Created files:"
echo "  $RSA_DIR/server-rsa.key"
echo "  $RSA_DIR/server-rsa.crt"
echo "  $ECDSA_DIR/server-ecdsa.key"
echo "  $ECDSA_DIR/server-ecdsa.crt"
echo "  $PQ_DIR/server-pq.key"
echo "  $PQ_DIR/server-pq.crt"
echo
echo "[*] Quick certificate summaries:"
openssl x509 -in "$RSA_DIR/server-rsa.crt" -noout -subject
openssl x509 -in "$ECDSA_DIR/server-ecdsa.crt" -noout -subject
openssl x509 -in "$PQ_DIR/server-pq.crt" -noout -subject
