#!/usr/bin/env bash
# End-to-end smoke test: build → deploy → create_bounty → claim_bounty → complete_bounty
# Required env vars:
#   ACCOUNT  - funded testnet account (e.g. GXXXXXXX...)
#   NETWORK  - network passphrase alias (default: testnet)

set -euo pipefail

NETWORK="${NETWORK:-testnet}"

if [[ -z "${ACCOUNT:-}" ]]; then
  echo "ERROR: ACCOUNT environment variable is required (a funded testnet account public key)." >&2
  exit 1
fi

echo "==> [1/5] Building WASM..."
cargo build --target wasm32-unknown-unknown --release
WASM_FILE=$(find target/wasm32-unknown-unknown/release -name "*.wasm" | head -1)
if [[ -z "$WASM_FILE" ]]; then
  echo "ERROR: No WASM artifact found after build." >&2
  exit 1
fi
echo "    Built: $WASM_FILE"

echo "==> [2/5] Deploying contract to $NETWORK..."
CONTRACT_ID=$(stellar contract deploy \
  --wasm "$WASM_FILE" \
  --source "$ACCOUNT" \
  --network "$NETWORK" 2>&1 | tail -1)
if [[ -z "$CONTRACT_ID" ]]; then
  echo "ERROR: Contract deployment failed." >&2
  exit 1
fi
echo "    Contract ID: $CONTRACT_ID"

echo "==> [3/5] Creating bounty..."
BOUNTY_ID=$(stellar contract invoke \
  --id "$CONTRACT_ID" \
  --source "$ACCOUNT" \
  --network "$NETWORK" \
  -- create_bounty \
  --creator "$ACCOUNT" \
  --title "Smoke Test Bounty" \
  --description "Automated smoke test" \
  --reward 100 \
  --deadline 9999999999 2>&1 | tail -1)
if [[ -z "$BOUNTY_ID" ]]; then
  echo "ERROR: create_bounty did not return an ID." >&2
  exit 1
fi
echo "    Bounty ID: $BOUNTY_ID"

echo "==> [4/5] Claiming bounty..."
CLAIM_STATUS=$(stellar contract invoke \
  --id "$CONTRACT_ID" \
  --source "$ACCOUNT" \
  --network "$NETWORK" \
  -- claim_bounty \
  --bounty_id "$BOUNTY_ID" \
  --claimant "$ACCOUNT" 2>&1 | tail -1)
echo "    Claim status: $CLAIM_STATUS"

echo "==> [5/5] Completing bounty..."
COMPLETE_RESULT=$(stellar contract invoke \
  --id "$CONTRACT_ID" \
  --source "$ACCOUNT" \
  --network "$NETWORK" \
  -- complete_bounty \
  --bounty_id "$BOUNTY_ID" \
  --creator "$ACCOUNT" 2>&1 | tail -1)
echo "    Complete result: $COMPLETE_RESULT"

echo ""
echo "Smoke test passed successfully."
