#!/usr/bin/env bash
set -euo pipefail

INTERFACE=""
SERVER_HOST=""
SERVER_IP=""
SERVERNAME="localhost"
OUTDIR="./captures"
CLIENT_BIN="/opt/openssl-3.5/bin/openssl"
TCPDUMP_BIN="tcpdump"
TIMEOUT_SECS="8"
PORTS="8443,8444,8445,8446,8447,8448,8449"
SLEEP_BEFORE_CONNECT="1"
SLEEP_AFTER_CONNECT="1"
INSECURE="0"
CERT_DIR="/opt/oqs-client/certs"

usage() {
  cat <<EOF
Usage: sudo $0 -i INTERFACE -h SERVER_HOST_OR_IP [options]

Required:
  -i, --interface IFACE      Interface to capture on
  -h, --host HOST            Server hostname or IP

Optional:
  -s, --servername NAME      TLS SNI name (default: localhost)
  -o, --outdir DIR           Output directory (default: ./captures)
  -c, --client PATH          OpenSSL client binary (default: /opt/openssl-3.5/bin/openssl)
  -t, --timeout SECONDS      Timeout per connection (default: 8)
  -p, --ports LIST           Comma-separated ports (default: 8443,8444,8445,8446,8447,8448,8449)
      --tcpdump PATH         tcpdump binary (default: tcpdump)
      --cert-dir DIR         Cert directory (default: /opt/oqs-client/certs)
      --insecure             Skip CA verification
      --sleep-before SEC     Sleep before connect (default: 1)
      --sleep-after SEC      Sleep after connect (default: 1)
      --help                 Show help

Examples:
  sudo $0 -i eth0 -h 10.0.0.20
  sudo $0 -i ens5 -h 10.0.0.20 -p 8445,8448,8449
  sudo $0 -i eth0 -h server.example.com -o /tmp/oqs-captures
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--interface)
      INTERFACE="$2"
      shift 2
      ;;
    -h|--host)
      SERVER_HOST="$2"
      shift 2
      ;;
    -s|--servername)
      SERVERNAME="$2"
      shift 2
      ;;
    -o|--outdir)
      OUTDIR="$2"
      shift 2
      ;;
    -c|--client)
      CLIENT_BIN="$2"
      shift 2
      ;;
    -t|--timeout)
      TIMEOUT_SECS="$2"
      shift 2
      ;;
    -p|--ports)
      PORTS="$2"
      shift 2
      ;;
    --tcpdump)
      TCPDUMP_BIN="$2"
      shift 2
      ;;
    --cert-dir)
      CERT_DIR="$2"
      shift 2
      ;;
    --insecure)
      INSECURE="1"
      shift
      ;;
    --sleep-before)
      SLEEP_BEFORE_CONNECT="$2"
      shift 2
      ;;
    --sleep-after)
      SLEEP_AFTER_CONNECT="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Run as root so tcpdump can capture packets"
  exit 1
fi

if [[ -z "${INTERFACE}" || -z "${SERVER_HOST}" ]]; then
  usage
  exit 1
fi

if [[ ! -x "${CLIENT_BIN}" ]]; then
  echo "Client binary not found or not executable: ${CLIENT_BIN}"
  exit 1
fi

if ! command -v "${TCPDUMP_BIN}" >/dev/null 2>&1; then
  echo "tcpdump not found: ${TCPDUMP_BIN}"
  exit 1
fi

declare -A TLS_GROUPS
declare -A CAFILES
declare -A LABELS

TLS_GROUPS[8443]="X25519:P-256"
CAFILES[8443]="${CERT_DIR}/rsa.crt"
LABELS[8443]="RSA cert + classical KEX"

TLS_GROUPS[8444]="P-384:X25519"
CAFILES[8444]="${CERT_DIR}/ecdsa.crt"
LABELS[8444]="ECDSA cert + classical KEX"

TLS_GROUPS[8445]="MLKEM768"
CAFILES[8445]="${CERT_DIR}/mldsa65.crt"
LABELS[8445]="ML-DSA-65 cert + MLKEM768"

TLS_GROUPS[8446]="MLKEM768"
CAFILES[8446]="${CERT_DIR}/rsa.crt"
LABELS[8446]="RSA cert + MLKEM768"

TLS_GROUPS[8447]="X25519:P-256"
CAFILES[8447]="${CERT_DIR}/mldsa65.crt"
LABELS[8447]="ML-DSA-65 cert + classical KEX"

TLS_GROUPS[8448]="MLKEM512"
CAFILES[8448]="${CERT_DIR}/mldsa44.crt"
LABELS[8448]="ML-DSA-44 cert + MLKEM512"

TLS_GROUPS[8449]="MLKEM1024"
CAFILES[8449]="${CERT_DIR}/mldsa87.crt"
LABELS[8449]="ML-DSA-87 cert + MLKEM1024"

SERVER_IP="$(getent ahosts "${SERVER_HOST}" | awk '{print $1; exit}')"
if [[ -z "${SERVER_IP}" ]]; then
  if [[ "${SERVER_HOST}" =~ ^[0-9a-fA-F:.]+$ ]]; then
    SERVER_IP="${SERVER_HOST}"
  else
    echo "Could not resolve server host: ${SERVER_HOST}"
    exit 1
  fi
fi

SAFE_SERVER_IP="$(echo "${SERVER_IP}" | tr ':' '_')"

mkdir -p "${OUTDIR}"

cleanup_tcpdump() {
  local pid="$1"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    kill -INT "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  fi
}

run_one_capture() {
  local port="$1"
  local groups="$2"
  local cafile="$3"
  local label="$4"
  local ts
  local base
  local pcap_file
  local keylog_file
  local log_file
  local tcpdump_pid
  local -a cmd
  local -a ca_args

  ts="$(date +%Y%m%d_%H%M%S)"
  base="${OUTDIR}/client_${SAFE_SERVER_IP}_port${port}_${ts}"
  pcap_file="${base}.pcap"
  keylog_file="${base}.keys"
  log_file="${base}.log"

  echo
  echo "================================================================"
  echo "Port:        ${port}"
  echo "Profile:     ${label}"
  echo "Server host: ${SERVER_HOST}"
  echo "Server IP:   ${SERVER_IP}"
  echo "Interface:   ${INTERFACE}"
  echo "Groups:      ${groups}"
  echo "PCAP:        ${pcap_file}"
  echo "Keys:        ${keylog_file}"
  echo "Log:         ${log_file}"
  echo "----------------------------------------------------------------"

  if [[ "${INSECURE}" == "0" ]]; then
    if [[ ! -f "${cafile}" ]]; then
      echo "CA file not found: ${cafile}"
      return 1
    fi
    ca_args=(-CAfile "${cafile}")
  else
    ca_args=()
  fi

  : > "${keylog_file}"
  chmod 600 "${keylog_file}"

  "${TCPDUMP_BIN}" -i "${INTERFACE}" -U -s 0 -n \
    -w "${pcap_file}" \
    "host ${SERVER_IP} and tcp port ${port}" >/dev/null 2>&1 &
  tcpdump_pid=$!

  sleep "${SLEEP_BEFORE_CONNECT}"

  cmd=(
    timeout "${TIMEOUT_SECS}"s
    "${CLIENT_BIN}" s_client
    -connect "${SERVER_HOST}:${port}"
    -servername "${SERVERNAME}"
    -tls1_3
    -groups "${groups}"
    -keylogfile "${keylog_file}"
    "${ca_args[@]}"
    -brief
    -showcerts
  )

  {
    echo "Client command:"
    printf '%q ' "${cmd[@]}"
    echo
    echo
    printf '' | "${cmd[@]}"
  } > "${log_file}" 2>&1 || true

  sleep "${SLEEP_AFTER_CONNECT}"

  cleanup_tcpdump "${tcpdump_pid}"

  echo "Saved files:"
  echo "  ${pcap_file}"
  echo "  ${keylog_file}"
  echo "  ${log_file}"

  echo "Handshake summary:"
  egrep 'Protocol version|Ciphersuite|Signature type|Server Temp Key|Verification|Verify return code|Peer certificate' "${log_file}" || true

  echo "Cert summary:"
  awk '
    /Subject:/ || /Signature Algorithm:/ || /Public Key Algorithm:/ { print }
  ' "${log_file}" || true

  echo "Packet count preview:"
  "${TCPDUMP_BIN}" -nn -r "${pcap_file}" 2>/dev/null | head -n 5 || true
}

IFS=',' read -r -a PORT_ARRAY <<<"${PORTS}"

echo "Using client:    ${CLIENT_BIN}"
echo "Using tcpdump:   ${TCPDUMP_BIN}"
echo "Server host:     ${SERVER_HOST}"
echo "Server IP:       ${SERVER_IP}"
echo "Interface:       ${INTERFACE}"
echo "Output dir:      ${OUTDIR}"
echo "Verify certs:    $([[ "${INSECURE}" == "0" ]] && echo yes || echo no)"

for port in "${PORT_ARRAY[@]}"; do
  if [[ -z "${TLS_GROUPS[$port]:-}" ]]; then
    echo
    echo "Skipping unknown port: ${port}"
    continue
  fi
  run_one_capture "${port}" "${TLS_GROUPS[$port]}" "${CAFILES[$port]}" "${LABELS[$port]}"
done

echo
echo "Done."
echo "In Wireshark, set the TLS '(Pre)-Master-Secret log filename' to the matching .keys file."
echo "Each port has its own .pcap and .keys file in: ${OUTDIR}"
