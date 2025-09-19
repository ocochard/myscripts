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

## dd

```
diskutil list
sudo diskutil unmountDisk disk4
xzcat file.img.xz | sudo dd of=/dev/rdisk4 bs=1m
sudo sync
```

# Bugs

## Floating App icons

A years old bug, with a simple bad mouse movement in the Launchpad, the icon of the app will stay on the screen:
```
killall Dock
```

