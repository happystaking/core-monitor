#!/bin/bash

# Configuration variables
notifyEmailAddress=
cardanoNodeSocket=
prometheusQueryUri=
remoteCorePrometheusAlias=
remoteCoreAddress=
remoteCorePort=
connectivityCheckIP=8.8.8.8
blockHeightDiffThreshold=
secondsSleepMainLoop=30

# Script variables
network=${1:-mainnet}
localIsForging=false
dependencies=(cardano-cli cncli curl jq)

# Function definitions
function getLocalBlockHeight {
    block=$(cardano-cli query tip --socket-path $cardanoNodeSocket --${network} | jq -r ".block")
    if [ "x$block" != "x" ]; then echo $block; else echo 0; fi
}

function getRemoteBlockHeight {
    block=$(curl -ks "${prometheusQueryUri}"?query=cardano_node_metrics_blockNum_int | jq -r ".data.result[] | select(.metric.alias == \"${remoteCorePrometheusAlias}\") | .value[1]")
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

function activateLocalCore {
    echo "stage: 3; sending SIGHUP to cardano-node to enable block producing mode"
    kill -s HUP $(pidof cardano-node)
    journalctl -r -n 9 -u core-monitor@${network}.service | mail -s "Backup core activated" $notifyEmailAddress
}

function deactivateLocalCore {
    echo "stage: 2; restarting cardano-node in non-producing mode"
    systemctl restart cardano-core@mainnet
    journalctl -r -n 9 -u core-monitor@${network}.service | mail -s "Backup core deactivated" $notifyEmailAddress
}

# Dependency checks
for binary in ${dependencies[@]}
do
    if ! which $binary &>/dev/null;
    then
        echo "Can't find $binary; please try to (re)install $binary or edit your \$PATH"
        exit 1
    fi
done

# Main loop
while :
do
    secondsNow=$(date +%s)
    localBlockHeight=$(getLocalBlockHeight)
    remoteCncliState=$(getRemoteCncliState)
    remoteBlockHeight=$(getRemoteBlockHeight)
    connectivityState=$(getConnectivityState)
    blockHeightDiff=$(getBlockHeightDiff $localBlockHeight $remoteBlockHeight)

    echo "stage: 1; local height: $localBlockHeight; remote height: $remoteBlockHeight; diff: $blockHeightDiff"

    # The difference between the local block height and block height reported by remote Prometheus is above the threshold (remote core is lagging behind).
    if [[ $blockHeightDiff -gt $blockHeightDiffThreshold ]];
    then
        echo "stage: 2; threshold: $blockHeightDiffThreshold; diff: $blockHeightDiff; remote cncli: $remoteCncliState; connectivity: $connectivityState"

        # Activate the local core only if we have connectivity, if we're not forging blocks already and when the remote block height is:
        # not reported (0) and cncli reports an error, or when the remote block height is reported (not 0) and above the threshold.
        # Keep in mind that when the remote height is reported and over threshold we have two producers running and forking could potentially happen.
        if [[ "$connectivityState" == "ok" && "$localIsForging" == false && ( ( "$remoteCncliState" == "error" && "$remoteBlockHeight" == "0" ) || "$remoteBlockHeight" != "0" )]];
        then
            localIsForging=true
            activateLocalCore

            echo "stage: 3; activated: local core; remote cncli: $remoteCncliState; forging: $localIsForging; connectivity: $connectivityState; diff: $blockHeightDiff"
        # Just logging that the local BP is currently running.
        elif [[ "$localIsForging" == true ]];
        then
            echo "stage: 3; running: local core; remote cncli: $remoteCncliState; forging: $localIsForging; connectivity: $connectivityState; diff: $blockHeightDiff"
        # Error reported by cncli because we have no internet connectivity.
        elif [[ "$connectivityState" == "error" ]];
        then
            echo "stage: 3; skipping: local core; remote cncli: $remoteCncliState; forging: $localIsForging; connectivity: $connectivityState; diff: $blockHeightDiff"
        fi
    fi

    # Disable the local core if the height diff is 0 or above, below threshold again, cncli reports success and we're forging blocks locally.
    if [[ $blockHeightDiff -ge 0 && $blockHeightDiff -le $blockHeightDiffThreshold && "$remoteCncliState" == "ok" && "$localIsForging" == true ]];
    then
        localIsForging=false
        deactivateLocalCore

        echo "stage: 2; deactivated: local core; remote cncli: $remoteCncliState; forging: $localIsForging; connectivity: $connectivityState; diff: $blockHeightDiff"
    fi

    sleep $secondsSleepMainLoop
done
