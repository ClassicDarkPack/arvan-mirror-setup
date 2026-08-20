# Arvan Mirror Setup

A simple bash script to automatically configure Ubuntu's APT package sources to use the [ArvanCloud](https://www.arvancloud.ir/) mirror instead of the default Ubuntu archive servers. Useful for significantly faster package downloads for users in Iran.

## What it does

- Auto-detects your Ubuntu codename (e.g. `focal`, `jammy`, `noble`)
- Backs up your existing APT source files
- Rewrites both the legacy `/etc/apt/sources.list` file and the newer `/etc/apt/sources.list.d/ubuntu.sources` (deb822 format, used on Ubuntu 24.04 "noble" and later) to point to the ArvanCloud mirror
- Runs `apt update` to verify the new configuration

## Usage

### Quick install (one-liner)

```bash
curl -sL https://raw.githubusercontent.com/ClassicDarkPack/arvan-mirror-setup/main/setup-arvan-mirror.sh | bash
```

### Manual install (recommended, review before running)

```bash
curl -sL -o setup-arvan-mirror.sh https://raw.githubusercontent.com/ClassicDarkPack/arvan-mirror-setup/main/setup-arvan-mirror.sh
chmod +x setup-arvan-mirror.sh
cat setup-arvan-mirror.sh   # review the contents before running
./setup-arvan-mirror.sh
```

## Notes

- Requires `sudo` privileges.
- Original source files are backed up with a `.bak` extension before being overwritten.
- Tested on Ubuntu 24.04 (noble). Should also work on earlier LTS releases (20.04, 22.04) that still use `sources.list`.

## Restoring the original configuration

```bash
sudo cp /etc/apt/sources.list.bak /etc/apt/sources.list
sudo cp /etc/apt/sources.list.d/ubuntu.sources.bak /etc/apt/sources.list.d/ubuntu.sources
sudo apt update
```
