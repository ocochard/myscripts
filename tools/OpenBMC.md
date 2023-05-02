# OpenBMC

# [Redfish](https://github.com/openbmc/docs/blob/master/REDFISH-cheatsheet.md)

Globals variable used:
```
bmc=bmc.ip.ad.dress
token=$(curl -k -H "Content-Type: application/json" -X POST https://$bmc/login -d '{"username" :  "root", "password" :  "0penBmc"}' | awk -F'"' '/token/ {print $4;}')
```
You can use the user/pass way:

```
curl -u username:password ...
```

Or the Token way:
```
curl -H "X-Auth-Token: $token" ...
```

Listing firmwares installed:

```
curl -k -H "X-Auth-Token: $token" -X GET https://${bmc}/redfish/v1/UpdateService/FirmwareInventory
```

Listing firmware details (@odata.id variable from previous output):
```
curl -k -H "X-Auth-Token: $token" -X GET https://${bmc}/redfish/v1/UpdateService/FirmwareInventory/XXXX
```

Upgrading firmware:

```
curl -k -H "X-Auth-Token: $token" -X POST -i -H "Content-Typation/octet-stream" -T bmc-firmware-version.tar https://${bmc}/redfish/v1/UpdateService
curl -k -H "X-Auth-Token: $token" -i -d '{"ResetType": "GracefulRestart"}' https://${bmc}/redfish/v1/Managers/bmc/Actions/Manager.Reset
sleep 10; ping -o $bmc && echo BMC rebooted
```
