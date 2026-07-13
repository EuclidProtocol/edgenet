#!/bin/bash
set -e


BINARY="${BINARY:-lumend}"


DENOM="${DENOM:-ualpha}"
STAKE_DENOM="${STAKE_DENOM:-usync}"

# Bash never strips quotes from an expansion result, so a value like "lumend"
# (quotes included) would build CHAIN_HOME as /"lumend"/."lumend" and hand curl
# an unusable URL. Fail before anything is deleted, downloaded, or created.
for var in BINARY CHAIN_ID DENOM STAKE_DENOM SNAPSHOT_URL; do
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

edit_client () {
    # Expose the rpc
    dasel put -t string -f $CONFIG_FOLDER/client.toml '.keyring-backend' -v "test"
    dasel put -t string -f $CONFIG_FOLDER/client.toml '.chain-id' -v $CHAIN_ID
}

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

edit_client

echo "🔑 Adding validator account"
echo $VALIDATOR_MNEMONIC | $BINARY keys add $VALIDATOR_MONIKER --keyring-backend test --home $CHAIN_HOME --recover

VALIDATOR_ADDRESS=$($BINARY keys show -a $VALIDATOR_MONIKER --keyring-backend test --home $CHAIN_HOME)

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


echo "🏁 Starting $CHAIN_ID..."
$BINARY in-place-testnet $CHAIN_ID $VALIDATOR_ADDRESS \
    --home $CHAIN_HOME \
    --accounts-to-fund euclid1z328t58xya5hw32a869n6hah33uaehw5zz9rj3 \
    --coins-to-fund 1000000000000$STAKE_DENOM,1000000000000$DENOM
