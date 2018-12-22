#!/bin/bash
# Local split version by webworker01
# Original version by Decker (c) 2018 <https://github.com/DeckerSU/komodo_scripts/blob/master/split_nn_sapling.sh>
#
# Requires package dc - sudo apt-get install dc
#
# Usage: ./splitfunds <COINNAME> <numutxos> <sapling=1/0>
# e.g.   ./splitfunds KMD 50
# e.g.   ./splitfunds OOT 50 0

#cd "${BASH_SOURCE%/*}" || exit

#coin=$1
#duplicates=$2
#curl http://127.0.0.1:7776 --silent --data "{\"coin\":\"${coin}\",\"agent\":\"iguana\",\"method\":\"splitfunds\",\"satoshis\":10000,\"sendflag\":1,\"duplicates\":${duplicates}}"

NN_ADDRESS=$(./printkey.py Radd)

#Full path to komodo-cli
komodoexec=/usr/local/bin/komodo-cli

#Do not change below for any reason!

#base58 decode by grondilu https://github.com/grondilu/bitcoin-bash-tools/blob/master/bitcoin.sh
declare -a base58=(
      1 2 3 4 5 6 7 8 9
    A B C D E F G H   J K L M N   P Q R S T U V W X Y Z
    a b c d e f g h i j k   m n o p q r s t u v w x y z
)
unset dcr; for i in {0..57}; do dcr+="${i}s${base58[i]}"; done
decodeBase58() {
    local line
    echo -n "$1" | sed -e's/^\(1*\).*/\1/' -e's/1/00/g' | tr -d '\n'
    dc -e "$dcr 16o0$(sed 's/./ 58*l&+/g' <<<$1)p" |
    while read line; do echo -n ${line/\\/}; done
}

if [[ ! -z $1 ]] && [[ $1 != "KMD" ]]; then
    coin=$1
    asset=" -ac_name=$1"
else
    coin="KMD"
    asset=""
fi

SPLIT_COUNT=$2
#Splits > 252 are not allowed
if [[ ! -z $SPLIT_COUNT ]] && (( SPLIT_COUNT > 252 )); then
    SPLIT_COUNT=252
elif [[ ! -z $SPLIT_COUNT ]] && (( SPLIT_COUNT > 0 )); then
    SPLIT_COUNT=$2
else
    #it wasn't a number, default to 50
    SPLIT_COUNT=50
fi

if [[ ! -z $3 ]] && [[ $3 != "1" ]]; then
    sapling=0
else
    sapling=1
fi

SPLIT_VALUE=0.0001
SPLIT_VALUE_SATOSHI=10000
SPLIT_TOTAL=$(jq -n "$SPLIT_VALUE*$SPLIT_COUNT")
SPLIT_TOTAL_SATOSHI=$(jq -n "$SPLIT_VALUE*$SPLIT_COUNT*100000000")

NN_PUBKEY=$($komodoexec $asset validateaddress $NN_ADDRESS | jq -r .pubkey)
nob58=$(decodeBase58 $NN_ADDRESS)
NN_HASH160=$(echo ${nob58:2:-8})

#Get lowest amount and valid utxo to split
if [[ $coin != "VRSC" ]]; then
    utxo=$($komodoexec $asset listunspent | jq -r --arg minsize $SPLIT_TOTAL '[.[] | select(.amount>($minsize|tonumber) and .generated==false and .rawconfirmations>0)] | sort_by(.amount)[0]')
else
    utxo=$($komodoexec $asset listunspent | jq -r --arg minsize $SPLIT_TOTAL '[.[] | select(.amount>($minsize|tonumber) and .generated==false and .confirmations>0)] | sort_by(.amount)[0]')
fi

if [[ $utxo != "null" ]]; then

    txid=$(echo "$utxo" | jq -r .txid)
    vout=$(echo "$utxo" | jq -r .vout)
    amount=$(echo "$utxo" | jq -r .amount)

    rev_txid=$(echo $txid | dd conv=swab 2> /dev/null | rev)
    vout_hex=$(printf "%08x" $vout | dd conv=swab 2> /dev/null | rev)

    if (( sapling > 0 )); then
        rawtx="04000080" # tx version
        rawtx=$rawtx"85202f89" # versiongroupid
    else
        rawtx="01000000" # tx version
    fi

    rawtx=$rawtx"01" # number of inputs (1, as we take one utxo from listunspent)
    rawtx=$rawtx$rev_txid$vout_hex"00ffffffff"

    oc=$((SPLIT_COUNT+1))
    outputCount=$(printf "%02x" $oc)

    rawtx=$rawtx$outputCount
    for (( i=1; i<=$SPLIT_COUNT; i++ )); do
        value=$(printf "%016x" $SPLIT_VALUE_SATOSHI | dd conv=swab 2> /dev/null | rev)
        rawtx=$rawtx$value
        rawtx=$rawtx"2321"$NN_PUBKEY"ac"
    done

    #change=$(echo "$amount*100000000-$SPLIT_TOTAL_SATOSHI/1*1" | bc -l | sed '/\./ s/\.\{0,1\}0\{1,\}$//')
    #change=$(jq -n "(${amount}-${SPLIT_TOTAL})*100000000")
    change=$(echo "($amount-$SPLIT_TOTAL)*100000000" | bc -l | sed '/\./ s/\.\{0,1\}0\{1,\}$//')

    value=$(printf "%016x" $change | dd conv=swab 2> /dev/null | rev)

    rawtx=$rawtx$value
    rawtx=$rawtx"1976a914"$NN_HASH160"88ac" # len OP_DUP OP_HASH160 len hash OP_EQUALVERIFY OP_CHECKSIG

    nlocktime=$(printf "%08x" $(date +%s) | dd conv=swab 2> /dev/null | rev)
    rawtx=$rawtx$nlocktime

    if (( sapling > 0 )); then
        rawtx=$rawtx"000000000000000000000000000000" # sapling end of tx
    fi

    signedtx=$($komodoexec $asset signrawtransaction $rawtx | jq -r '.hex')

    if [[ ! -z $signedtx ]]; then
        txid=$($komodoexec $asset sendrawtransaction $signedtx)
        echo '{"txid":"'"$txid"'"}'
    else
        echo '{"error":"failed to sign tx"}'
    fi
else
  echo '{"error":"No UTXOs to split :(("}'
fi

