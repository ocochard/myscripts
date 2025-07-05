# netdata

https://www.netdata.cloud/

## Basic example on Ubuntu

```
sudo apt install -y lm-sensors netdata
sudo /etc/netdata/edit-config --list
sudo /etc/netdata/edit-config netdata.conf
# bind socket to IP = 0.0.0.0
cat <<EOF | sudo tee /etc/netdata/go.d/sensors.conf
## All available configuration options, their descriptions and default values:
## https://github.com/netdata/netdata/tree/master/src/go/plugin/go.d/collector/sensors#readme

jobs:
  - name: sensors
    binary_path: /usr/bin/sensors
EOF

sudo systemctl restart netdata
```
