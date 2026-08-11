generating tls pcaps showcasing classical, hybrid, and pqc algorithms

# TLS Port Configuration Summary

This document summarizes the TLS certificate algorithms and key exchange groups configured on each server port.

## Concepts

In this setup, each TLS listener is defined by two main choices:

- **Certificate algorithm**: the algorithm used by the server certificate to authenticate the server
- **Key exchange group**: the algorithm or group used during the TLS handshake to establish the shared session secret

These are separate parts of TLS:

- The **certificate** proves server identity
- The **key exchange** establishes encryption keys for the session

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
- **Purpose**: baseline classical TLS configuration using an RSA certificate

### Port 8444
- **Certificate**: ECDSA
- **Key exchange**: `P-384` or `X25519`
- **Purpose**: baseline classical TLS configuration using an ECDSA certificate

### Port 8445
- **Certificate**: ML-DSA-65
- **Key exchange**: `MLKEM768`
- **Purpose**: full post-quantum TLS profile with both PQ certificate authentication and PQ key establishment

### Port 8446
- **Certificate**: RSA
- **Key exchange**: `MLKEM768`
- **Purpose**: mixed profile using a classical certificate with post-quantum key exchange

### Port 8447
- **Certificate**: ML-DSA-65
- **Key exchange**: `X25519` or `P-256`
- **Purpose**: mixed profile using a post-quantum certificate with classical key exchange

### Port 8448
- **Certificate**: ML-DSA-44
- **Key exchange**: `MLKEM512`
- **Purpose**: lower-size PQ profile for testing smaller ML-DSA and ML-KEM parameter sets

### Port 8449
- **Certificate**: ML-DSA-87
- **Key exchange**: `MLKEM1024`
- **Purpose**: larger-size PQ profile for testing higher-security ML-DSA and ML-KEM parameter sets

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

## Expected Handshake Characteristics

When testing with `openssl s_client`:

- **Signature type** should reflect the certificate algorithm
- **Server Temp Key** should reflect the negotiated key exchange group

Examples:

- On **8443**, expect:
  - certificate auth: RSA
  - key exchange: `X25519` or `P-256`

- On **8444**, expect:
  - certificate auth: ECDSA
  - key exchange: `P-384` or `X25519`

- On **8445**, expect:
  - certificate auth: ML-DSA-65
  - key exchange: `MLKEM768`

- On **8446**, expect:
  - certificate auth: RSA
  - key exchange: `MLKEM768`

- On **8447**, expect:
  - certificate auth: ML-DSA-65
  - key exchange: `X25519` or `P-256`

- On **8448**, expect:
  - certificate auth: ML-DSA-44
  - key exchange: `MLKEM512`

- On **8449**, expect:
  - certificate auth: ML-DSA-87
  - key exchange: `MLKEM1024`

## Files Typically Used

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

## Summary

This server is configured to demonstrate:

- classical TLS with RSA and ECDSA certificates
- post-quantum TLS with ML-DSA certificates
- post-quantum key exchange with ML-KEM
- mixed classical/PQ combinations for interoperability and testing

The port layout gives you examples of:

- **classical certificate + classical key exchange**
- **classical certificate + PQ key exchange**
- **PQ certificate + classical key exchange**
- **PQ certificate + PQ key exchange**
