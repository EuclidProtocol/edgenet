#!/bin/bash
set -e


BINARY="${BINARY:-lumend}"


DENOM="${DENOM:-ualpha}"
STAKE_DENOM="${STAKE_DENOM:-usync}"

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
