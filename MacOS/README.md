# Setup

Force terminal to use English:

```
echo 'export LANG="en_EN.UTF-8"' >> ~/.zshrc
```

Install personnal software suite:
```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
echo 'export PATH="/opt/homebrew/bin:$PATH"' >> ~/.zshrc
brew install tmux therm htop git jq keepassxc calibre freetube utm monitorcontrol coteditor keepingyouawake vlc avidemux
```
