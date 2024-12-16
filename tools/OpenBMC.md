# OpenBMC

## Using

### [Redfish](https://github.com/openbmc/docs/blob/master/REDFISH-cheatsheet.md)

Globals variable used:
```
bmc=bmc.ip.ad.dress
token=$(curl -k -H "Content-Type: application/json" -X POST https://$bmc/login -d '{"username" :  "root", "password" :  "0penBmc"}' | awk -F'"' '/token/ {print $4;}')
```

Or [pure Redfish](https://www.dmtf.org/sites/default/files/Redfish_School-Sessions.pdf):

```
curl -k -H "Content-Type: application/json" -X GET https://$bmc/redfish/v1/ | jq '.SessionService'
```

You can use the user/pass way:

```
curl -u username:password ...
```

Or the Token way:
```
curl -H "X-Auth-Token: $token" ...
```

Listing BMC firmwares installed:

```
curl -k -H "X-Auth-Token: $token" -X GET https://${bmc}/redfish/v1/UpdateService/FirmwareInventory
```

Listing BMC firmware details (@odata.id variable from previous output):
```
curl -k -H "X-Auth-Token: $token" -X GET https://${bmc}/redfish/v1/UpdateService/FirmwareInventory/XXXX
```

Upgrading BMC firmware:

```
curl -k -H "X-Auth-Token: $token" -X POST -i -H "Content-Typation/octet-stream" -T bmc-firmware-version.tar https://${bmc}/redfish/v1/UpdateService
curl -k -H "X-Auth-Token: $token" -i -d '{"ResetType": "GracefulRestart"}' https://${bmc}/redfish/v1/Managers/bmc/Actions/Manager.Reset
sleep 10; ping -o $bmc && echo BMC rebooted
```

### From BMC shell

```
root@s8030:/etc# cat /etc/os-release
ID="openbmc-phosphor"
NAME="Phosphor OpenBMC (Phosphor OpenBMC Project Reference Distro)"
VERSION="v4.44-0-g1eaa82ef8a-s8030"
VERSION_ID="v4.44-0-g1eaa82ef8a-s8030"
PRETTY_NAME="Phosphor OpenBMC (Phosphor OpenBMC Project Reference Distro) v4.44-0-g1eaa82ef8a-s8030"
BMC_NAME="S8030"
BUILD_ID="20240105223010"
OPENBMC_TARGET_MACHINE="s8030"
```

#### Entity-manager

Troubleshooting the Entity-manager.
Used to apply differents paramter to differents motherboard type

```
journalctl -t entity-manager
```

Configuration files here as example:
```
/usr/share/entity-manager/configurations/s8030-Baseboard.json
```

## Building

Need about 100G free disk space.
From a Ubuntu 24.04:
```
echo "Fix permission error on Ubuntu 24.04: https://bugs.launchpad.net/ubuntu/+source/apparmor/+bug/2056555"
sudo apparmor_parser -R /etc/apparmor.d/unprivileged_userns

git clone https://github.com/openbmc/openbmc.git
cd openbmc
. setup s8036
bitbake obmc-phosphor-image
```

At the file, file in `build/s8036/tmp/deploy/images/s8036/image-bmc`

