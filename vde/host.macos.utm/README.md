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
brew install powershell
brew install openssl qemu wget
```

## Next: Create a Guest VM

After completing the host setup, follow the instructions for your guest operating system:

- [Amazon Linux](guest.amazon.linux/README.md)
- [Ubuntu Desktop](guest.ubuntu.desktop/README.md)

## Troubleshooting

If you run into problems, see [common issues and solutions](troubleshooting.md).
