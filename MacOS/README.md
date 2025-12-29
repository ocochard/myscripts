# Setup

## Terminal

Force terminal to use English:

```
echo 'export LANG="en_EN.UTF-8"' >> ~/.zshrc
```

## Personnal software suite

Install personnal software suite:
```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
echo 'export PATH="/opt/homebrew/bin:$PATH"' >> ~/.zshrc
brew install tmux therm htop git jq keepassxc calibre freetube utm monitorcontrol coteditor keepingyouawake vlc avidemux
```

## Allow TouchID for sudo

Remove comment in sudo_local_template:
```
sudo cp /etc/pam.d/sudo_local.template /etc/pam.d/sudo_local
sudo sed -i '' 's/#auth/auth/' /etc/pam.d/sudo_local
```

To works with tmux it need a pam-reattach module.
```
brew install pam-reattach
test -r /opt/homebrew/lib/pam/pam_reattach.so && echo "you can continue" || echo "stop here the pam_reattach.so is missing, you will break sudo"
cat <<EOF | sudo tee /etc/pam.d/sudo_local
auth       optional       /opt/homebrew/lib/pam/pam_reattach.so
auth       sufficient     pam_tid.so
EOF
```

## Sending email from terminal (postfix)

The mail(1) command use postfix (`/etc/postfix/main.cf`) on MacOS.
Example with gmail SMTP server.

Create an alias between your local username and email:
```
cat <<EOF | sudo tee -a /etc/postfix/main.cf
relayhost = [smtp.gmail.com]:587
# TLS
smtp_use_tls = yes
smtp_tls_security_level=encrypt
# SASL auth
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
smtp_sasl_mechanism_filter = plain
EOF
echo '[smtp.gmail.com]:587 GMAIL_USERNAME@gmail.com:MDP_Application' | sudo tee -a /etc/postfix/sasl_passwd
```

Configure email address mapping:
```
echo "$USER@$(hostname) GMAIL_USERNAME@gmail.com" | sudo tee -a /etc/postfix/generic
```

Restart postfix:
```
sudo chmod 400 /etc/postfix/sasl_passwd
sudo postmap /etc/postfix/sasl_passwd
sudo postmap /etc/postfix/generic
sudo launchctl stop org.postfix.master
sudo launchctl start org.postfix.master
```

Now test it, in one terminal star a live log:
```
log stream --predicate  '(process == "smtpd") || (process == "smtp")' --info
```

And in a second terminal session, send an email:
```
echo 'test' | mail -s "testing macos’s postfix" someone@domain
```

## dd

```
diskutil list
sudo diskutil unmountDisk disk4
xzcat file.img.xz | sudo dd of=/dev/rdisk4 bs=1m
sudo sync
```

## Cleanup all partitions in USB disk

```
diskutil list
sudo diskutil umountDisk disk4
diskutil eraseDisk ExFAT DisqueUSB GPT disk
```

## Create Install Media

Insert a 32GB USB stick and format it (default: GUID, Apple_HFS) with label "MacOS_Tahoe" for this example.
Then download installer and prepare the USB stick with it.

First display your disk id:
```
diskutil list
```

On this example we will consider it to be "disk4":
```
diskutil eraseDisk HFS+ MacOS_Tahoe disk4
softwareupdate --list-full-installers
softwareupdate --fetch-full-installer --full-installer-version 26.0.1
sudo /Applications/Install\ macOS\ Tahoe.app/Contents/Resources/createinstallmedia --volume /Volumes/MacOS_Tahoe
```

# Bugs

## Floating App icons

A years old bug, with a simple bad mouse movement in the Launchpad, the icon of the app will stay on the screen:
```
killall Dock
```

