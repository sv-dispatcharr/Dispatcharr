#!/bin/sh
set -e

REPO="Dispatcharr/Dispatcharr"
BASE="https://github.com/${REPO}/releases/latest/download"
KEYRING="/etc/apt/keyrings/dispatcharr.gpg"
SOURCELIST="/etc/apt/sources.list.d/dispatcharr.list"

if [ "$(id -u)" -ne 0 ]; then
  echo "error: run with sudo" >&2
  exit 1
fi

install -d -m 755 /etc/apt/keyrings
curl -fsSL "${BASE}/key.gpg" | gpg --dearmor -o "$KEYRING"
echo "deb [signed-by=${KEYRING}] ${BASE} ./" > "$SOURCELIST"

apt-get update -o Dir::Etc::sourcelist="$SOURCELIST" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup=0
echo "Done. Run: apt-get install dispatcharr"
