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
