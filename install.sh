#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${REPO:-YOURNAME/LOVENN}"
BRANCH="${BRANCH:-main}"
URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/Love.sh"

echo "[INFO] Installing Love from: ${URL}"
bash <(wget -qO- "${URL}")
