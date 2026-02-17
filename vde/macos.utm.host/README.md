# macOS UTM Host Setup

One-time setup instructions for preparing a macOS host with UTM.

## Install Homebrew

Check latest instructions for `brew` from [brew.sh](https://brew.sh/)

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

After installing `brew`, you may need to open another terminal.

## Install Required Tools

```bash
brew install --cask utm
brew install git
brew install powershell/tap/powershell
brew install openssl qemu xz wget
```
