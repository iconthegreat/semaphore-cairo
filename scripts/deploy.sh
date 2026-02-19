#!/usr/bin/env bash
set -euo pipefail

# Deploy Semaphore contracts to starknet-devnet or Sepolia
# Usage: ./scripts/deploy.sh devnet|sepolia

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VERIFIER_DIR="$PROJECT_ROOT/semaphore_verifier"
CONTRACTS_DIR="$PROJECT_ROOT/contracts"
OUTPUT_FILE="$SCRIPT_DIR/deployed-addresses.json"

SCARB_2_14="/home/icon/.asdf/installs/scarb/2.14.0/bin/scarb"

NETWORK="${1:-}"
if [[ -z "$NETWORK" ]]; then
  echo "Usage: $0 <devnet|sepolia>"
  exit 1
fi

# ── 1. Build verifier with scarb 2.14.0 ──────────────────────────────
echo "==> Building verifier (scarb 2.14.0)..."
if [[ ! -x "$SCARB_2_14" ]]; then
  echo "ERROR: scarb 2.14.0 not found at $SCARB_2_14"
  echo "Install with: asdf install scarb 2.14.0"
  exit 1
fi
(cd "$VERIFIER_DIR" && "$SCARB_2_14" build)

# ── 2. Build contracts with default scarb ─────────────────────────────
echo "==> Building contracts..."
(cd "$CONTRACTS_DIR" && scarb build)

# ── 3. Network-specific setup ─────────────────────────────────────────
DEVNET_PID=""

cleanup() {
  if [[ -n "$DEVNET_PID" ]]; then
    echo "==> Stopping devnet (pid $DEVNET_PID)..."
    kill "$DEVNET_PID" 2>/dev/null || true
    wait "$DEVNET_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ "$NETWORK" == "devnet" ]]; then
  RPC_URL="http://127.0.0.1:5050"

  # Check if devnet is already running
  if curl -s "$RPC_URL/is_alive" >/dev/null 2>&1; then
    echo "==> Devnet already running at $RPC_URL"
  else
    echo "==> Starting starknet-devnet..."
    starknet-devnet --port 5050 --seed 0 > /tmp/devnet-deploy.log 2>&1 &
    DEVNET_PID=$!
    for i in $(seq 1 30); do
      if curl -s "$RPC_URL/is_alive" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
    if ! curl -s "$RPC_URL/is_alive" >/dev/null 2>&1; then
      echo "ERROR: Devnet failed to start within 30 seconds"
      exit 1
    fi
    echo "==> Devnet started (pid $DEVNET_PID)"
  fi

  # Fetch prefunded account via JSON-RPC (devnet 0.7+)
  ACCOUNTS_JSON=$(curl -s -X POST "$RPC_URL" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"devnet_getPredeployedAccounts","params":{},"id":1}')
  ACCOUNT_ADDRESS=$(echo "$ACCOUNTS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['address'])")
  PRIVATE_KEY=$(echo "$ACCOUNTS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['private_key'])")

  echo "   Account: $ACCOUNT_ADDRESS"

  # Import account into sncast
  sncast account import \
    --name devnet-deployer \
    --address "$ACCOUNT_ADDRESS" \
    --private-key "$PRIVATE_KEY" \
    --type oz \
    --url "$RPC_URL" \
    --add-profile devnet-deployer \
    --silent 2>/dev/null || true

  SNCAST_URL="$RPC_URL"
  SNCAST_ACCOUNT="devnet-deployer"

elif [[ "$NETWORK" == "sepolia" ]]; then
  RPC_URL="${STARKNET_RPC_URL:-https://free-rpc.nethermind.io/sepolia-juno/v0_7}"
  if [[ -z "${STARKNET_ACCOUNT:-}" ]]; then
    echo "ERROR: STARKNET_ACCOUNT env var required for Sepolia deployment"
    echo "Set: export STARKNET_ACCOUNT=<your-account-name>"
    exit 1
  fi
  SNCAST_URL="$RPC_URL"
  SNCAST_ACCOUNT="$STARKNET_ACCOUNT"
else
  echo "ERROR: Unknown network '$NETWORK'. Use 'devnet' or 'sepolia'."
  exit 1
fi

echo "==> Deploying to $NETWORK (rpc: $RPC_URL)"

# ── 3.5. Declare Garaga ECIP ops class (required by verifier) ────────
ECIP_SIERRA="$VERIFIER_DIR/ecip_artifacts/universal_ecip_UniversalECIP.contract_class.json"
ECIP_CASM="$VERIFIER_DIR/ecip_artifacts/universal_ecip_UniversalECIP.compiled_contract_class.json"

if [[ "$NETWORK" == "devnet" && -f "$ECIP_SIERRA" && -f "$ECIP_CASM" ]]; then
  echo "==> Declaring Garaga ECIP ops class on devnet..."
  # Use node.js to declare since sncast requires a Scarb project
  ECIP_RESULT=$(cd "$PROJECT_ROOT/sdk" && node -e "
    const { RpcProvider, Account, Signer, json } = require('starknet');
    const fs = require('fs');
    (async () => {
      const provider = new RpcProvider({nodeUrl: '$RPC_URL'});
      const signer = new Signer('$PRIVATE_KEY');
      const account = new Account({provider, address: '$ACCOUNT_ADDRESS', signer});
      const sierra = json.parse(fs.readFileSync('$ECIP_SIERRA', 'utf-8'));
      const casm = json.parse(fs.readFileSync('$ECIP_CASM', 'utf-8'));
      try {
        const result = await account.declareIfNot({contract: sierra, casm});
        if (result.transaction_hash) {
          await provider.waitForTransaction(result.transaction_hash);
        }
        console.log('class_hash:' + result.class_hash);
      } catch(e) {
        if (e.message && e.message.includes('already declared')) {
          console.log('class_hash:already_declared');
        } else {
          console.error(e.message);
          process.exit(1);
        }
      }
    })();
  " 2>&1)
  echo "   ECIP ops: $ECIP_RESULT"
else
  echo "==> Skipping ECIP declaration (already on Sepolia or artifacts missing)"
fi

# ── 4. Declare & deploy verifier ──────────────────────────────────────
echo "==> Declaring verifier..."

# sncast needs to run from the project directory to find Scarb.toml and artifacts
VERIFIER_DECLARE_OUTPUT=$(cd "$VERIFIER_DIR" && sncast \
  --account "$SNCAST_ACCOUNT" declare \
  --url "$SNCAST_URL" --contract-name Groth16VerifierBN254 2>&1) || {
  if echo "$VERIFIER_DECLARE_OUTPUT" | grep -q "already declared"; then
    echo "   Verifier already declared"
  else
    echo "$VERIFIER_DECLARE_OUTPUT"
    exit 1
  fi
}

VERIFIER_CLASS_HASH=$(echo "$VERIFIER_DECLARE_OUTPUT" | grep -oP 'class_hash: \K0x[0-9a-fA-F]+' || true)
if [[ -z "$VERIFIER_CLASS_HASH" ]]; then
  VERIFIER_CLASS_HASH=$(echo "$VERIFIER_DECLARE_OUTPUT" | grep -oP '0x[0-9a-fA-F]{50,}' | head -1)
fi
echo "   Verifier class hash: $VERIFIER_CLASS_HASH"

echo "==> Deploying verifier..."
VERIFIER_DEPLOY_OUTPUT=$(sncast \
  --account "$SNCAST_ACCOUNT" deploy \
  --url "$SNCAST_URL" --class-hash "$VERIFIER_CLASS_HASH" 2>&1)
VERIFIER_ADDRESS=$(echo "$VERIFIER_DEPLOY_OUTPUT" | grep -oP 'contract_address: \K0x[0-9a-fA-F]+' || true)
if [[ -z "$VERIFIER_ADDRESS" ]]; then
  VERIFIER_ADDRESS=$(echo "$VERIFIER_DEPLOY_OUTPUT" | grep -oP '0x[0-9a-fA-F]{50,}' | head -1)
fi
echo "   Verifier address: $VERIFIER_ADDRESS"

# ── 5. Declare & deploy Semaphore ─────────────────────────────────────
echo "==> Declaring Semaphore..."
SEMAPHORE_DECLARE_OUTPUT=$(cd "$CONTRACTS_DIR" && sncast \
  --account "$SNCAST_ACCOUNT" declare \
  --url "$SNCAST_URL" --contract-name Semaphore 2>&1) || {
  if echo "$SEMAPHORE_DECLARE_OUTPUT" | grep -q "already declared"; then
    echo "   Semaphore already declared"
  else
    echo "$SEMAPHORE_DECLARE_OUTPUT"
    exit 1
  fi
}

SEMAPHORE_CLASS_HASH=$(echo "$SEMAPHORE_DECLARE_OUTPUT" | grep -oP 'class_hash: \K0x[0-9a-fA-F]+' || true)
if [[ -z "$SEMAPHORE_CLASS_HASH" ]]; then
  SEMAPHORE_CLASS_HASH=$(echo "$SEMAPHORE_DECLARE_OUTPUT" | grep -oP '0x[0-9a-fA-F]{50,}' | head -1)
fi
echo "   Semaphore class hash: $SEMAPHORE_CLASS_HASH"

echo "==> Deploying Semaphore (verifier=$VERIFIER_ADDRESS)..."
SEMAPHORE_DEPLOY_OUTPUT=$(sncast \
  --account "$SNCAST_ACCOUNT" deploy \
  --url "$SNCAST_URL" --class-hash "$SEMAPHORE_CLASS_HASH" \
  --constructor-calldata "$VERIFIER_ADDRESS" 2>&1)
SEMAPHORE_ADDRESS=$(echo "$SEMAPHORE_DEPLOY_OUTPUT" | grep -oP 'contract_address: \K0x[0-9a-fA-F]+' || true)
if [[ -z "$SEMAPHORE_ADDRESS" ]]; then
  SEMAPHORE_ADDRESS=$(echo "$SEMAPHORE_DEPLOY_OUTPUT" | grep -oP '0x[0-9a-fA-F]{50,}' | head -1)
fi
echo "   Semaphore address: $SEMAPHORE_ADDRESS"

# ── 6. Write output ───────────────────────────────────────────────────
cat > "$OUTPUT_FILE" <<EOF
{
  "network": "$NETWORK",
  "rpc_url": "$RPC_URL",
  "verifier": {
    "class_hash": "$VERIFIER_CLASS_HASH",
    "address": "$VERIFIER_ADDRESS"
  },
  "semaphore": {
    "class_hash": "$SEMAPHORE_CLASS_HASH",
    "address": "$SEMAPHORE_ADDRESS"
  }
}
EOF

echo ""
echo "==> Deployment complete!"
echo "   Verifier: $VERIFIER_ADDRESS"
echo "   Semaphore: $SEMAPHORE_ADDRESS"
echo "   Addresses written to: $OUTPUT_FILE"
