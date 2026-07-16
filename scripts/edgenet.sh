#!/bin/bash
set -e


BINARY="${BINARY:-lumend}"


DENOM="${DENOM:-ualpha}"
STAKE_DENOM="${STAKE_DENOM:-usync}"

# Bash never strips quotes from an expansion result, so a value like "lumend"
# (quotes included) would build CHAIN_HOME as /"lumend"/."lumend" and hand curl
# an unusable URL. Fail before anything is deleted, downloaded, or created.
# The check is only about quote characters, so an empty value passes it: that
# matters for FUNDED_ACCOUNTS, which is legitimately empty when no extra
# development accounts are configured.
for var in BINARY CHAIN_ID DENOM STAKE_DENOM SNAPSHOT_URL FUNDED_ACCOUNTS COSMWASM_ADMIN; do
    value="${!var:-}"
    case "$value" in
        *\"*|*\'*)
            echo "FATAL: environment variable $var contains a literal quote character: $value" >&2
            echo "       This usually means the value is quoted in .env; remove the surrounding quotes." >&2
            exit 1
            ;;
    esac
done

# HOME does not come from the runtime environment: Dockerfile.edgenet bakes it
# as `ENV HOME /${BINARY}` from the BINARY build arg. A quoted BINARY at build
# time is therefore frozen into the image layer, and a clean .env today does not
# undo it. Fixing .env alone leaves CHAIN_HOME as /"lumend"/.lumend, so check
# HOME separately and point at the remedy that actually works.
case "$HOME" in
    *\"*|*\'*)
        echo "FATAL: HOME contains a literal quote character: $HOME" >&2
        echo "       HOME is baked into the image at build time from the BINARY build arg," >&2
        echo "       so this image was built while BINARY was quoted. Editing .env will not" >&2
        echo "       fix it. Rebuild the image (e.g. 'make edgenet', which passes --build)." >&2
        exit 1
        ;;
esac

CHAIN_HOME=$HOME/.$BINARY
CONFIG_FOLDER=$CHAIN_HOME/config


edit_config () {
    # Expose the rpc
    dasel put -t string -f $CONFIG_FOLDER/config.toml '.rpc.laddr' -v "tcp://0.0.0.0:26657"

    dasel put -t string -f $CONFIG_FOLDER/config.toml '.moniker' -v "edgenet-validator"
}

edit_client () {
    dasel put -t string -f $CONFIG_FOLDER/client.toml '.keyring-backend' -v "test"
    dasel put -t string -f $CONFIG_FOLDER/client.toml '.chain-id' -v $CHAIN_ID
}

edit_app () {
    local APP=$CONFIG_FOLDER/app.toml

    # Enable lcd
    dasel put -t bool -f $APP '.api.enable' -v true
    dasel put -t bool -f $APP '.api.enabled-unsafe-cors' -v true
    dasel put -t string -f $APP '.api.address' -v "tcp://0.0.0.0:1317"
    dasel put -t bool -f $APP '.api.swagger' -v true
    dasel put -t string -f $APP '.grpc.address' -v "0.0.0.0:9090"
    dasel put -t bool -f $APP '.grpc.enable' -v true
    # Gas Price
    dasel put -t string -f $APP 'minimum-gas-prices' -v "0.015$DENOM"
}


# CHAIN_HOME is a bind mount (docker-compose.yml maps ./.config/${CHAIN_ID}_edgenet/
# onto it), so this sentinel outlives the container. Its presence means the chain was
# already built here: skip the whole setup path and just start the node again, instead
# of wiping the home and rebuilding the chain from the snapshot on every restart.
if [ -f "$CHAIN_HOME/initialized" ]; then
    echo "♻️  Existing chain found at $CHAIN_HOME (initialized), skipping setup."
    echo "🏁 Starting $CHAIN_ID from existing state..."
    exec $BINARY start --home $CHAIN_HOME \
        --rpc.laddr tcp://0.0.0.0:26657 \
        --api.enable true \
        --api.swagger true \
        --api.enabled-unsafe-cors true
fi

echo "🆕 No existing chain at $CHAIN_HOME, building it from the snapshot."

# Clear the CONTENTS of the home directory, not the directory itself.
# docker-compose.yml bind-mounts a host directory at /${BINARY}/.${BINARY}/, which
# is exactly CHAIN_HOME. A live mountpoint cannot be unlinked from inside the
# container, so `rm -rf $CHAIN_HOME/` fails with EBUSY and set -e kills us.
# -mindepth 1 picks up dotfiles and is a no-op on an empty directory; mkdir -p
# covers the case where the mount is absent (e.g. running the image directly).
mkdir -p "$CHAIN_HOME"
find "$CHAIN_HOME" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

echo "🧪 Creating home for $VALIDATOR_MONIKER"
echo $VALIDATOR_MNEMONIC | $BINARY init $VALIDATOR_MONIKER --chain-id $CHAIN_ID --home $CHAIN_HOME --default-denom $DENOM --recover



# Copy genesis
echo -e "\nCopying genesis file..."
cp $HOME/genesis.json $CONFIG_FOLDER/genesis.json
echo ✅ Genesis file copied successfully.

# Copy config.toml
echo -e "\nCopying config.toml file..."
cp $HOME/config.toml $CONFIG_FOLDER/config.toml
echo ✅ Config.toml file copied successfully.

edit_config
edit_app
edit_client

echo "🔑 Adding validator account"
echo $VALIDATOR_MNEMONIC | $BINARY keys add $VALIDATOR_MONIKER --keyring-backend test --home $CHAIN_HOME --recover

# The account address (euclid1...) and the operator address (euclidvaloper1...) are
# the same key in two bech32 prefixes. in-place-testnet wants the operator form for
# --validator-operator and the account form for --accounts-to-fund/--cosmwasm-admin.
VAL_ACCOUNT=$($BINARY keys show -a $VALIDATOR_MONIKER --keyring-backend test --home $CHAIN_HOME)
VAL_OPERATOR=$($BINARY keys show $VALIDATOR_MONIKER --bech val -a --keyring-backend test --home $CHAIN_HOME)

# SNAPSHOT_URL is a metadata endpoint, not the archive itself. It answers with
# JSON of the form {"height":25667070,"url":"https://.../lumen-1_25667070.tar.lz4",...}
# and the archive lives at .url.
echo "🔎 Resolving snapshot metadata from $SNAPSHOT_URL"
if ! SNAPSHOT_META=$(curl -fsSL "$SNAPSHOT_URL"); then
    echo "FATAL: could not fetch snapshot metadata from $SNAPSHOT_URL" >&2
    exit 1
fi

# A wrong-but-live endpoint can answer 200 with an empty body, which curl -f
# reports as success, so an exit code of 0 is not proof of a usable response.
if [ -z "$SNAPSHOT_META" ]; then
    echo "FATAL: snapshot metadata endpoint $SNAPSHOT_URL returned an empty body" >&2
    exit 1
fi

if ! echo "$SNAPSHOT_META" | jq -e . >/dev/null 2>&1; then
    echo "FATAL: snapshot metadata endpoint $SNAPSHOT_URL did not return JSON:" >&2
    echo "$SNAPSHOT_META" >&2
    exit 1
fi

SNAPSHOT_ARCHIVE_URL=$(echo "$SNAPSHOT_META" | jq -r '.url // empty')
SNAPSHOT_HEIGHT=$(echo "$SNAPSHOT_META" | jq -r '.height // empty')

if [ -z "$SNAPSHOT_ARCHIVE_URL" ]; then
    echo "FATAL: snapshot metadata from $SNAPSHOT_URL has no .url field:" >&2
    echo "$SNAPSHOT_META" >&2
    exit 1
fi

# The height is the cache key, so a metadata endpoint pointing at a different
# height cannot be served the previously cached archive. Without it every
# snapshot would collide on one filename.
if [ -z "$SNAPSHOT_HEIGHT" ]; then
    echo "FATAL: snapshot metadata from $SNAPSHOT_URL has no .height field:" >&2
    echo "$SNAPSHOT_META" >&2
    exit 1
fi

SNAPSHOT_FILE=$HOME/cache/snapshot-$SNAPSHOT_HEIGHT.tar.lz4

echo "📦 Snapshot at height $SNAPSHOT_HEIGHT: $SNAPSHOT_ARCHIVE_URL"

# Download the snapshot if this height is not already cached
if [ ! -f "$SNAPSHOT_FILE" ]; then
  echo -e "\nCache is empty for height $SNAPSHOT_HEIGHT. Downloading snapshot..."
  mkdir -p "$HOME/cache"
  # Download to a temporary name and rename only on success, so an interrupted
  # download is never mistaken for a complete cache entry on the next run.
  curl -fL "$SNAPSHOT_ARCHIVE_URL" -o "$SNAPSHOT_FILE.part"
  mv "$SNAPSHOT_FILE.part" "$SNAPSHOT_FILE"
  echo -e ✅ Snapshot downloaded successfully.
else
  echo "✅ Snapshot for height $SNAPSHOT_HEIGHT already cached."
fi

echo "♻️  Restoring snapshot at height $SNAPSHOT_HEIGHT"

lz4 -dc $SNAPSHOT_FILE | tar -C $CHAIN_HOME/ -xf -

# The consensus key is read HERE, after the snapshot has been extracted, and not
# right after `init`. Order matters: the snapshot tarball can carry its own config/
# and overwrite the priv_validator_key.json that `init` generated. Reading it earlier
# would hand in-place-testnet a consensus key that no longer matches the one on disk,
# and the converted chain would refuse to sign blocks.
PRIV_VALIDATOR_KEY=$CONFIG_FOLDER/priv_validator_key.json

echo "🔐 Reading the consensus key from $PRIV_VALIDATOR_KEY"
if [ ! -f "$PRIV_VALIDATOR_KEY" ]; then
    echo "FATAL: $PRIV_VALIDATOR_KEY does not exist after restoring the snapshot." >&2
    echo "       in-place-testnet needs the consensus key of this node; refusing to continue." >&2
    exit 1
fi

# Nothing below ever prints the file or the private key: this is the node's consensus
# signing key. jq's output is redirected, and the error paths quote only the path.
if ! jq -e . "$PRIV_VALIDATOR_KEY" >/dev/null 2>&1; then
    echo "FATAL: $PRIV_VALIDATOR_KEY is not valid JSON." >&2
    echo "       Its contents are secret, so they are not shown here." >&2
    exit 1
fi

CONSENSUS_PUBKEY=$(jq -r '.pub_key.value // empty' "$PRIV_VALIDATOR_KEY")
CONSENSUS_PRIVKEY=$(jq -r '.priv_key.value // empty' "$PRIV_VALIDATOR_KEY")

if [ -z "$CONSENSUS_PUBKEY" ]; then
    echo "FATAL: $PRIV_VALIDATOR_KEY has no .pub_key.value" >&2
    exit 1
fi

if [ -z "$CONSENSUS_PRIVKEY" ]; then
    echo "FATAL: $PRIV_VALIDATOR_KEY has no .priv_key.value" >&2
    exit 1
fi

# The validator account is always funded; FUNDED_ACCOUNTS (comma separated, may be
# empty) adds the development accounts on top. Empty must not produce a trailing
# comma, which in-place-testnet would read as an empty address and reject.
ACCOUNTS_TO_FUND=$VAL_ACCOUNT
if [ -n "${FUNDED_ACCOUNTS:-}" ]; then
    ACCOUNTS_TO_FUND=$ACCOUNTS_TO_FUND,$FUNDED_ACCOUNTS
fi

# The cosmwasm admin defaults to the validator account so a bare .env still
# yields a usable testnet; COSMWASM_ADMIN overrides it when contract migration
# rights need to live on a different (e.g. externally held) account.
COSMWASM_ADMIN="${COSMWASM_ADMIN:-$VAL_ACCOUNT}"

# Written before in-place-testnet because in-place-testnet never returns (it converts
# the restored state and then runs the node), so there is no "after" to write it in.
# Accepted tradeoff: a conversion that dies partway leaves this sentinel over a
# half-converted home and the next restart will `start` against it. Escape hatch:
# `make clean`, or delete $CHAIN_HOME/initialized, to force a rebuild from scratch.
touch "$CHAIN_HOME/initialized"

echo "🏁 Starting $CHAIN_ID..."
echo "👤 Validator operator: $VAL_OPERATOR"
echo "💰 Funding accounts: $ACCOUNTS_TO_FUND"
echo "🛠️  Cosmwasm admin: $COSMWASM_ADMIN"
$BINARY in-place-testnet $CHAIN_ID \
    --validator-operator=$VAL_OPERATOR \
    --validator-pubkey=$CONSENSUS_PUBKEY \
    --validator-privkey=$CONSENSUS_PRIVKEY \
    --accounts-to-fund=$ACCOUNTS_TO_FUND \
    --cosmwasm-admin=$COSMWASM_ADMIN \
    --home $CHAIN_HOME \
    --coins-to-fund 1000000000000$DENOM,1000000000000$STAKE_DENOM
