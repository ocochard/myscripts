# Smokeping

[Examples on FreeBSD](https://www.digitalocean.com/community/tutorials/how-to-track-network-latency-with-smokeping-on-freebsd-11)

## smokeping itself

```
pkg install smokeping
cat <EOF > /usr/local/etc/smokeping/config
(etc.)
imgcache = /usr/local/smokeping/htdocs/img/
imgurl   = http://127.0.0.1/smokeping/img/
datadir  = /usr/local/var/smokeping/
piddir  = /usr/local/var/smokeping/
cgiurl   = http://127.0.0.1/smokeping/smokeping.fcgi
(etc.)
*** Probes ***

+ FPing

binary = /usr/local/sbin/fping

+ DNS

binary = /usr/local/bin/dig
forks = 5
offset = 50%
step = 300
timeout = 15
(etc.)

*** Targets ***
(etc.)
++ Gateway

menu = Gateway
title = Default gateway
probe = FPing
host = 192.168.1.254

++ www-dns1
probe = DNS
host = www.free.fr resolved by dns1
lookup = www.free.fr
pings = 5
server = 8.8.8.8
(etc.)
EOF
service smokeping enable
service smokeping start
```

## FastCGI web server using Apache

```
sudo pkg install apache24 ap24-mod_fcgid
echo 'LoadModule fcgid_module libexec/apache24/mod_fcgid.so' | sudo tee /usr/local/etc/apache24/modules.d/001_fcgid.conf
cat <EOF | tail -usr/local/etc/apache24/Includes/smokeping.conf
ScriptAlias /smokeping.fcgi /usr/local/smokeping/htdocs/smokeping.fcgi
Alias       /smokeping      /usr/local/smokeping/htdocs/
<Directory "/usr/local/smokeping/htdocs/">
        AddHandler      fcgid-script .fcgi
        AllowOverride   None
        DirectoryIndex  index.html smokeping.fcgi
        Options         FollowSymLinks ExecCGI
        Require         all granted
</Directory>
EOF
service apache24 enable
service apache24 start
```
