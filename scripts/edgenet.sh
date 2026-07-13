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

SNAPSHOT_FILE=$HOME/cache/snapshot.tar.lz4

edit_client () {
    # Expose the rpc
    dasel put -t string -f $CONFIG_FOLDER/client.toml '.keyring-backend' -v "test"
    dasel put -t string -f $CONFIG_FOLDER/client.toml '.chain-id' -v $CHAIN_ID
}

# Clear home directory
rm -rf $CHAIN_HOME/

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

# Download latest snapshot if cache is empty
if [ ! -f "$SNAPSHOT_FILE" ]; then
  echo -e "\nCache is empty. Downloading latest snapshot..."
  curl -L $SNAPSHOT_URL -o $SNAPSHOT_FILE
  echo -e ✅ Snapshot downloaded successfully.
fi

lz4 -dc $SNAPSHOT_FILE | tar -C $CHAIN_HOME/ -xf -


echo "🏁 Starting $CHAIN_ID..."
$BINARY in-place-testnet $CHAIN_ID $VALIDATOR_ADDRESS \
    --home $CHAIN_HOME \
    --accounts-to-fund euclid1z328t58xya5hw32a869n6hah33uaehw5zz9rj3 \
    --coins-to-fund 1000000000000$STAKE_DENOM,1000000000000$DENOM
