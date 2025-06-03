#!/bin/bash

# Configuration variables
notifyEmailAddress=
cardanoNodeSocket=
prometheusQueryUri=
remoteCorePrometheusAlias=
remoteCoreAddress=
remoteCorePort=
remoteCheckAddress=
remoteCheckPort=
tunnelCheckPerform=false
tunnelCheckIPs=()
connectivityCheckIP=8.8.8.8
blockHeightDiffThreshold=
secondsSleepMainLoop=30
localCoreKeysPath=

# Script variables
network=${1:-mainnet}
localIsForging=false
dependencies=(cardano-cli curl jq)

# Dependency checks
for binary in ${dependencies[@]}
do
    if ! which $binary &>/dev/null;
    then
        echo "Can't find $binary; please try to (re)install $binary or edit your \$PATH"
        exit 1
    fi
done

# Sanity checks
if [[ ( ! -s "${localCoreKeysPath}/kes.skey" && ! -s "${localCoreKeysPath}/kes.skey.standby" ) ||
      ( ! -s "${localCoreKeysPath}/node.cert" && ! -s "${localCoreKeysPath}/node.cert.standby" ) ||
      ( ! -s "${localCoreKeysPath}/vrf.skey" && ! -s "${localCoreKeysPath}/vrf.skey.standby" ) ||
      ( ! -w "${localCoreKeysPath}" ) ]];
then
    echo "Error: the files kes.skey, node.cert and vrf.skey (or standby versions) must be present in $localCoreKeysPath and this script must have write permissions on that directory."
    exit 1;
fi

# Function definitions
function getLocalBlockHeight {
    block=$(cardano-cli query tip --socket-path $cardanoNodeSocket --${network} | jq -r ".block")
    if [ "x$block" != "x" ]; then echo $block; else echo 0; fi
}

function getRemoteBlockHeight {
    block=$(curl --connect-timeout 8 -ks "${prometheusQueryUri}"?query=cardano_node_metrics_blockNum_int | jq -r ".data.result[] | select(.metric.alias == \"${remoteCorePrometheusAlias}\") | .value[1]")
    if [ "x$block" != "x" ]; then echo $block; else echo 0; fi
}

function getBlockHeightDiff { # args: localBlockHeight remoteBlockHeight
    echo "$1 - $2" | bc
}

function getRemoteCoreState {
    tip=$(cardano-cli ping -jtqc 1 -h $remoteCoreAddress -p $remoteCorePort 2>/dev/null)
    if [ "$?" == "0" ]; then echo "$tip" | jq -r ".tip[0]"; else echo "error"; fi
}

function getRemoteCoreOnTip { #args: remoteCoreState localBlockHeight
    if [[ "$1" != "error" && `echo "${1}" | jq -r ".blockNo"` -ge $(( $2 - $blockHeightDiffThreshold )) ]]; then echo "true"; else echo "false"; fi
}

function getConnectivityState {
    ping -c 2 -w 4 $connectivityCheckIP &> /dev/null
    if [ "$?" == "0" ]; then echo "ok"; else echo "error"; fi
}

function getTunnelState {
    if [ "$tunnelCheckPerform" == "false" ]; then echo "ok" && return; fi
    for hostIP in "${tunnelCheckIPs[@]}"
    do
        ping -c 2 -w 4 $hostIP &> /dev/null
        if [ $? -eq 0 ]; then echo "ok" && return; fi
    done
    echo "error"
}

function getRemoteCheckState {
    echo `nmap -Pn $remoteCheckAddress -p $remoteCheckPort | awk 'FNR == 6 {print $2}'`
}

function activateLocalCore {
    echo "stage: 3; sending SIGHUP to cardano-node to enable block producing mode"
    kill -s HUP $(pidof cardano-node)
    journalctl -r -n 9 -u core-monitor@${network}.service | mail -s "Standby core activated" $notifyEmailAddress
}

function deactivateLocalCore {
    echo "stage: 2; unsetting keys and resetting cardano-node into non-producing mode"
    for f in kes.skey node.cert vrf.skey; do
        if [ -f "${localCoreKeysPath}/${f}" ]; then
            mv "${localCoreKeysPath}/${f}" "${localCoreKeysPath}/${f}.standby";
        fi
    done

    kill -s HUP $(pidof cardano-node)
    journalctl -r -n 9 -u core-monitor@${network}.service | mail -s "Standby core deactivated" $notifyEmailAddress
    sleep 30

    echo "stage: 2; restoring keys"
    for f in kes.skey node.cert vrf.skey; do
        if [ -f "${localCoreKeysPath}/${f}.standby" ]; then
            mv "${localCoreKeysPath}/${f}.standby" "${localCoreKeysPath}/${f}";
        fi
    done
}

# Main loop
while :
do
    localBlockHeight=$(getLocalBlockHeight)
    remoteBlockHeight=$(getRemoteBlockHeight)
    blockHeightDiff=$(getBlockHeightDiff $localBlockHeight $remoteBlockHeight)

    echo "stage: 1; local height: $localBlockHeight; remote height: $remoteBlockHeight; diff: $blockHeightDiff; threshold: $blockHeightDiffThreshold"

    # The difference between the local block height and block height reported by remote Prometheus is above the threshold.
    # The next step will use cardano-cli to confirm if the remote core is really lagging behind.
    if [[ $blockHeightDiff -gt $blockHeightDiffThreshold ]];
    then
        tunnelState=$(getTunnelState)
        remoteCoreState=$(getRemoteCoreState)
        remoteCheckState=$(getRemoteCheckState)
        remoteCoreOnTip=$(getRemoteCoreOnTip "$remoteCoreState" $localBlockHeight)
        connectivityState=$(getConnectivityState)

        echo "stage: 2; connectivity: $connectivityState; cardano-cli remote core on tip: $remoteCoreOnTip; tunnel: $tunnelState; check port: $remoteCheckState"

        # Activate the local core only under the condition that: we have connectivity, we're not forging blocks already, remote core is not on tip and:
        #  1) the remote block height is not reported (0) and the tunnel is ok, or
        #  2) the remote block height is not reported (0) and the remote check port is not open (host down), or
        #  3) the remote block height is reported (not 0), but is above the set threshold (checked in previous step). ATTN: in this case you have two producers running and forking could potentially happen!
        if [[ "$connectivityState" == "ok" && "$localIsForging" == false && "$remoteCoreOnTip" == "false" && ( "$tunnelState" == "ok" || "$remoteCheckState" != "open" ) ]];
        then
            localIsForging=true
            activateLocalCore
            echo "stage: 3; activated local core; local forging: $localIsForging; cardano-cli remote core on tip: $remoteCoreOnTip; tunnel state: $tunnelState; check port: $remoteCheckState"
        # Just logging that the local BP is currently running.
        elif [[ "$localIsForging" == true ]];
        then
            echo "stage: 3; forging on local core; local forging: $localIsForging; cardano-cli remote core on tip: $remoteCoreOnTip; tunnel state: $tunnelState; check port: $remoteCheckState"
        fi
    fi

    # Disable the local core if the height diff is 0 or above, below threshold again or cardano-cli reports success and we're forging blocks locally.
    if [[ ( $blockHeightDiff -ge 0 && $blockHeightDiff -le $blockHeightDiffThreshold || "$remoteCoreOnTip" == "true" ) && "$localIsForging" == true ]];
    then
        localIsForging=false
        deactivateLocalCore
        echo "stage: 2; deactivated local core; local forging: $localIsForging; cardano-cli remote core on tip: $remoteCoreOnTip"
    fi

    sleep $secondsSleepMainLoop
done
