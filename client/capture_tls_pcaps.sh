#!/usr/bin/env bash
set -euo pipefail

INTERFACE=""
SERVER_HOST=""
SERVER_IP=""
SERVERNAME="localhost"
OUTDIR="./pcaps"
CLIENT_CMD="oqs-sclient"
TIMEOUT_SECS="8"
PORTS="8443,8444,8445,8446,8447,8448,8449"
TCPDUMP_BIN="tcpdump"
SLEEP_BEFORE_CONNECT="1"
SLEEP_AFTER_CONNECT="1"

usage() {
  cat <<EOF
Usage: sudo $0 -i INTERFACE -h SERVER_HOST_OR_IP [options]

Required:
  -i, --interface IFACE      Network interface to capture on
  -h, --host HOST            Server hostname or IP

Optional:
  -s, --servername NAME      TLS SNI name to use (default: localhost)
  -o, --outdir DIR           Output directory for pcap files (default: ./pcaps)
  -c, --client-cmd CMD       Client command to run (default: oqs-sclient)
  -t, --timeout SECONDS      Client timeout in seconds (default: 8)
  -p, --ports LIST           Comma-separated port list
                             (default: 8443,8444,8445,8446,8447,8448,8449)
      --tcpdump PATH         Path to tcpdump binary (default: tcpdump)
      --sleep-before SEC     Sleep before client connect (default: 1)
      --sleep-after SEC      Sleep after client connect (default: 1)
      --help                 Show this help

Examples:
  sudo $0 -i eth0 -h 10.0.0.20
  sudo $0 -i ens5 -h server.example.com -o /tmp/pcaps
  sudo $0 -i eth0 -h 10.0.0.20 -p 8445,8447,8449
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
    -c|--client-cmd)
      CLIENT_CMD="$2"
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

if ! command -v "${TCPDUMP_BIN}" >/dev/null 2>&1; then
  echo "tcpdump not found: ${TCPDUMP_BIN}"
  exit 1
fi

if ! command -v "${CLIENT_CMD}" >/dev/null 2>&1; then
  echo "Client command not found: ${CLIENT_CMD}"
  exit 1
fi

SERVER_IP="$(getent ahostsv4 "${SERVER_HOST}" | awk '{print $1; exit}')"
if [[ -z "${SERVER_IP}" ]]; then
  if [[ "${SERVER_HOST}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SERVER_IP="${SERVER_HOST}"
  else
    echo "Could not resolve server host: ${SERVER_HOST}"
    exit 1
  fi
fi

mkdir -p "${OUTDIR}"

cleanup_tcpdump() {
  local pid="$1"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    kill -INT "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  fi
}

trap 'jobs -p | xargs -r kill -INT 2>/dev/null || true' EXIT

run_client_for_port() {
  local port="$1"

  timeout "${TIMEOUT_SECS}"s "${CLIENT_CMD}" \
    -h "${SERVER_HOST}" \
    -p "${port}" \
    -s "${SERVERNAME}" \
    -t "${TIMEOUT_SECS}" \
    --showcert || true
}

capture_one_port() {
  local port="$1"
  local ts
  local pcap_file
  local tcpdump_pid

  ts="$(date +%Y%m%d_%H%M%S)"
  pcap_file="${OUTDIR}/client_${SERVER_IP}_port${port}_${ts}.pcap"

  echo
  echo "=============================================================="
  echo "Capturing port ${port}"
  echo "Server host: ${SERVER_HOST}"
  echo "Server IP:   ${SERVER_IP}"
  echo "Interface:   ${INTERFACE}"
  echo "PCAP file:   ${pcap_file}"
  echo "--------------------------------------------------------------"

  "${TCPDUMP_BIN}" -i "${INTERFACE}" -U -s 0 -n \
    -w "${pcap_file}" \
    "host ${SERVER_IP} and tcp port ${port}" >/dev/null 2>&1 &
  tcpdump_pid=$!

  sleep "${SLEEP_BEFORE_CONNECT}"

  run_client_for_port "${port}"

  sleep "${SLEEP_AFTER_CONNECT}"

  cleanup_tcpdump "${tcpdump_pid}"

  if [[ -f "${pcap_file}" ]]; then
    echo "Saved: ${pcap_file}"
    "${TCPDUMP_BIN}" -nn -r "${pcap_file}" 2>/dev/null | head -n 10 || true
  else
    echo "Capture file was not created for port ${port}"
  fi
}

IFS=',' read -r -a PORT_ARRAY <<<"${PORTS}"

echo "Using tcpdump: ${TCPDUMP_BIN}"
echo "Using client:  ${CLIENT_CMD}"
echo "Server host:   ${SERVER_HOST}"
echo "Server IP:     ${SERVER_IP}"
echo "Interface:     ${INTERFACE}"
echo "Output dir:    ${OUTDIR}"

for port in "${PORT_ARRAY[@]}"; do
  capture_one_port "${port}"
done

echo
echo "Done. PCAP files are in: ${OUTDIR}"
