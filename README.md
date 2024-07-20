# core-monitor

A bash script that monitors your Cardano core node and activates a standby core node if needed.

## Operation

The script is meant to be run on the standby core. It will connect to your Prometheus endpoint to determine the main core block height. That height is compared to the height on the standby core. If the main core starts lagging behind and crosses the set threshold the standby core will be activated. The standby core will also be activated when the block height is not reported **and** cncli reports an error when connecting to the main core.

When the main core is back online and the block height is below threshold again, or cncli reports a successful connection, the standby core will be restarted in non-producing mode.

An optional tunnel check pings some IP's on the other side of the tunnel. If one IP replies the tunnel is considered up. Disable the tunnel check by setting `tunnelCheckPerform` to false.

## Installation

Copy `core-monitor@.service` to `/etc/systemd/system` and copy `core-monitor.sh` to `usr/local/bin`.

Open `/usr/local/bin/core-monitor.sh` in your favorite editor and edit the configuration variables to match your environment. The following variables are available:
```
notifyEmailAddress=mail@example.com
cardanoNodeSocket=/var/lib/cardano/mainnet/node.socket
prometheusQueryUri=https://prom.mypool.tld:443/api/v1
prometheusRemoteProducerAlias=main-core
remoteProducerAddress=core.mypool.tld
remoteProducerPort=3001
tunnelCheckPerform=true
tunnelCheckIPs=(10.0.0.1 10.0.0.2)
connectivityCheckIP=8.8.8.8
blockHeightDiffThreshold=10 #choose wisely
secondsSleepMainLoop=30
```

Save the file and run `systemctl enable --now core-monitor@mainnet` to run the script in the background and have it start on next system boot.

## Contributing

If you find this script useful, please consider delegating to ticker HAPPY.