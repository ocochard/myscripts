#!/bin/sh
#Generate fingerprint of SSH public key in DNS entry format
for key in /etc/ssh/ssh_host_*_key.pub; do \
        ssh-keygen -r `hostname` -f $key; \
done

