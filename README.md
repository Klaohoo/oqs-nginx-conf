cert generation


openssl genpkey \
  -algorithm RSA \
  -pkeyopt rsa_keygen_bits:3072 \
  -out /etc/nginx/certs/rsa/server-rsa.key

openssl req -new -x509 \
  -key /etc/nginx/certs/rsa/server-rsa.key \
  -out /etc/nginx/certs/rsa/server-rsa.crt \
  -days 3650 \
  -sha256 \
  -subj "/CN=classical-rsa.local" \
  -addext "subjectAltName=DNS:classical-rsa.local,DNS:hybrid-rsa.local,DNS:pqc-rsa.local"


PQSIG=MLDSA65

openssl genpkey \
  -provider default \
  -provider oqsprovider \
  -algorithm "$PQSIG" \
  -out /etc/nginx/certs/pq/server-pq.key

openssl req -new -x509 \
  -provider default \
  -provider oqsprovider \
  -key /etc/nginx/certs/pq/server-pq.key \
  -out /etc/nginx/certs/pq/server-pq.crt \
  -days 3650 \
  -subj "/CN=hybrid-pqcert.local" \
  -addext "subjectAltName=DNS:hybrid-pqcert.local,DNS:pqc-pqcert.local"

openssl genpkey \
  -algorithm EC \
  -pkeyopt ec_paramgen_curve:P-256 \
  -pkeyopt ec_param_enc:named_curve \
  -out /etc/nginx/certs/ecdsa/server-ecdsa.key

openssl req -new -x509 \
  -key /etc/nginx/certs/ecdsa/server-ecdsa.key \
  -out /etc/nginx/certs/ecdsa/server-ecdsa.crt \
  -days 3650 \
  -sha256 \
  -subj "/CN=classical-ecdsa.local" \
  -addext "subjectAltName=DNS:classical-ecdsa.local,DNS:hybrid-ecdsa.local,DNS:pqc-ecdsa.local"
