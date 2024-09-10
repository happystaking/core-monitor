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

# Script variables
network=${1:-mainnet}
localIsForging=false
dependencies=(cardano-cli cncli curl jq)

# Dependency checks
for binary in ${dependencies[@]}
do
    if ! which $binary &>/dev/null;
    then
        echo "Can't find $binary; please try to (re)install $binary or edit your \$PATH"
        exit 1
    fi
done

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

function getRemoteCncliState {
    echo `cncli ping -h $remoteCoreAddress -p $remoteCorePort | jq -r .status`
}

function getConnectivityState {
    ping -c 2 -w 4 $connectivityCheckIP &> /dev/null
    if [ "$?" == "0" ]; then echo "ok"; else echo "error"; fi
}

function getTunnelState {
    if [ "$tunnelCheckPerform" == "false" ]; then echo "ok1" && return; fi
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
    echo "stage: 2; restarting cardano-node in non-producing mode"
    systemctl restart cardano-core@mainnet
    journalctl -r -n 9 -u core-monitor@${network}.service | mail -s "Standby core deactivated" $notifyEmailAddress
}

# Main loop
while :
do
    localBlockHeight=$(getLocalBlockHeight)
    remoteCncliState=$(getRemoteCncliState)
    remoteBlockHeight=$(getRemoteBlockHeight)
    remoteCheckState=$(getRemoteCheckState)
    blockHeightDiff=$(getBlockHeightDiff $localBlockHeight $remoteBlockHeight)

    echo "stage: 1; local height: $localBlockHeight; remote height: $remoteBlockHeight; diff: $blockHeightDiff"

    # The difference between the local block height and block height reported by remote Prometheus is above the threshold (remote core is lagging behind).
    if [[ $blockHeightDiff -gt $blockHeightDiffThreshold ]];
    then
        tunnelState=$(getTunnelState)
        connectivityState=$(getConnectivityState)

        echo "stage: 2; threshold: $blockHeightDiffThreshold; diff: $blockHeightDiff; remote cncli: $remoteCncliState; connectivity: $connectivityState; tunnel: $tunnelState; check state: $remoteCheckState"

        # Activate the local core only under the prerequisite that: we have connectivity, we're not forging blocks already and:
        #  1) the remote block height is not reported (0), tunnel is ok, but cncli (through tunnel) reports an error, or
        #  2) the remote block height is not reported (0) and the remote check port is not open (host down), or
        #  3) the remote block height is reported (not 0), but is above the set threshold. ATTN: in this case you have two producers running and forking could potentially happen!
        if [[ "$connectivityState" == "ok" && "$localIsForging" == false && ( ( "$tunnelState" == "ok" && "$remoteCncliState" == "error" && "$remoteBlockHeight" == "0" ) ||  ( "$remoteBlockHeight" == "0" && "$remoteCheckState" != "open" ) || "$remoteBlockHeight" != "0" )]];
        then
            localIsForging=true
            activateLocalCore

            echo "stage: 3; activated: local core; remote cncli: $remoteCncliState; forging: $localIsForging; connectivity: $connectivityState; diff: $blockHeightDiff; check state: $remoteCheckState"
        # Just logging that the local BP is currently running.
        elif [[ "$localIsForging" == true ]];
        then
            echo "stage: 3; running: local core; remote cncli: $remoteCncliState; forging: $localIsForging; connectivity: $connectivityState; diff: $blockHeightDiff; check state: $remoteCheckState"
        # Error reported by cncli because we have no internet connectivity.
        elif [[ "$connectivityState" == "error" ]];
        then
            echo "stage: 3; skipping: local core; remote cncli: $remoteCncliState; forging: $localIsForging; connectivity: $connectivityState; diff: $blockHeightDiff; check state: $remoteCheckState"
        fi
    fi

    # Disable the local core if the height diff is 0 or above, below threshold again or cncli reports success and we're forging blocks locally.
    if [[ ( $blockHeightDiff -ge 0 && $blockHeightDiff -le $blockHeightDiffThreshold || "$remoteCncliState" == "ok" ) && "$localIsForging" == true ]];
    then
        localIsForging=false
        deactivateLocalCore

        echo "stage: 2; deactivated: local core; remote cncli: $remoteCncliState; forging: $localIsForging; connectivity: $connectivityState; diff: $blockHeightDiff; check state: $remoteCheckState"
    fi

    sleep $secondsSleepMainLoop
done
