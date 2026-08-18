generating tls pcaps showcasing classical, hybrid, and pqc algorithms

## Classical Algorithms Used

### Certificate algorithms
- **RSA**
- **ECDSA** using curve `prime256v1` (also called `P-256`)

### Key exchange groups
- **X25519**
- **P-256**
- **P-384**

## Post-Quantum Algorithms Used

### Certificate algorithms
- **ML-DSA-44**
- **ML-DSA-65**
- **ML-DSA-87**

### Key exchange groups
- **MLKEM512**
- **MLKEM768**
- **MLKEM1024**

## PCAP Contents

The PCAPs contain TLS1.3 traffic, captured from the client, establishing a connection to the server via openssl s_client. The exact command used is:

timeout 5s /opt/openssl-3.5/bin/openssl s_client \
  -connect SERVER:PORT \
  -servername localhost \
  -tls1_3 \
  -groups ALGORITHM \
  -CAfile CERTIFICATE \
  -keylogfile SECRETKEY \
  -showcerts



## Port-by-Port Summary

| Port | Certificate Algorithm | Certificate Key Type | TLS Key Exchange Group(s) | Description |
|------|------------------------|----------------------|----------------------------|-------------|
| 8443 | RSA | RSA | `X25519:P-256` | Classical certificate and classical key exchange |
| 8444 | ECDSA | ECDSA over `P-256` | `P-384:X25519` | Classical certificate and classical key exchange |
| 8445 | ML-DSA-65 | ML-DSA-65 | `MLKEM768` | Post-quantum certificate and post-quantum key exchange |
| 8446 | RSA | RSA | `MLKEM768` | Classical certificate and post-quantum key exchange |
| 8447 | ML-DSA-65 | ML-DSA-65 | `X25519:P-256` | Post-quantum certificate and classical key exchange |
| 8448 | ML-DSA-44 | ML-DSA-44 | `MLKEM512` | Smaller post-quantum certificate and smaller post-quantum key exchange |
| 8449 | ML-DSA-87 | ML-DSA-87 | `MLKEM1024` | Larger post-quantum certificate and larger post-quantum key exchange |

## Detailed Notes by Port

### Port 8443
- **Certificate**: RSA
- **Key exchange**: `X25519` or `P-256`

### Port 8444
- **Certificate**: ECDSA
- **Key exchange**: `P-384` or `X25519`

### Port 8445
- **Certificate**: ML-DSA-65
- **Key exchange**: `MLKEM768`

### Port 8446
- **Certificate**: RSA
- **Key exchange**: `MLKEM768`


### Port 8447
- **Certificate**: ML-DSA-65
- **Key exchange**: `X25519` or `P-256`


### Port 8448
- **Certificate**: ML-DSA-44
- **Key exchange**: `MLKEM512`


### Port 8449
- **Certificate**: ML-DSA-87
- **Key exchange**: `MLKEM1024`


## Configuration Matrix

| Port | Classical/PQ Certificate | Classical/PQ Key Exchange | Profile Type |
|------|---------------------------|---------------------------|--------------|
| 8443 | Classical | Classical | Classical / Classical |
| 8444 | Classical | Classical | Classical / Classical |
| 8445 | PQ | PQ | PQ / PQ |
| 8446 | Classical | PQ | Classical / PQ |
| 8447 | PQ | Classical | PQ / Classical |
| 8448 | PQ | PQ | PQ / PQ |
| 8449 | PQ | PQ | PQ / PQ |

## Files Used

### Certificates
- `rsa.crt`
- `ecdsa.crt`
- `mldsa44.crt`
- `mldsa65.crt`
- `mldsa87.crt`

### Private keys
- `rsa.key`
- `ecdsa.key`
- `mldsa44.key`
- `mldsa65.key`
- `mldsa87.key`

