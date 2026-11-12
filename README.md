<div align="center">

# Arvan Mirror Manager

**A safer Ubuntu APT mirror manager — with an interactive terminal menu, signed-metadata checks, and automatic mirror selection.**

[![CI](https://github.com/ClassicDarkPack/arvan-mirror-setup/actions/workflows/ci.yml/badge.svg)](https://github.com/ClassicDarkPack/arvan-mirror-setup/actions/workflows/ci.yml)
![Bash](https://img.shields.io/badge/Bash-5%2B-4EAA25?logo=gnubash&logoColor=white)
![Ubuntu](https://img.shields.io/badge/Ubuntu-amd64-E95420?logo=ubuntu&logoColor=white)

[Quick start](#quick-start) · [فارسی](#راهنمای-سریع-فارسی) · [Mirrors](#supported-mirrors) · [CLI](#command-reference) · [Safety](#safety-and-limitations)

</div>

> [!IMPORTANT]
> This tool changes Ubuntu APT sources. **Review the dry-run before applying**, and test on a disposable VM before using it on production servers. It currently targets **Ubuntu amd64 only**.

## Why this project?

Arvan Mirror Manager changes recognized Ubuntu package-source entries without replacing your entire configuration. It supports both traditional `sources.list` and deb822 `ubuntu.sources`, retains unrelated repositories and settings, and backs up modified sources before calling APT.

- **Interactive TUI:** navigate with ↑/↓, Enter, or numeric shortcuts over SSH.
- **Auto Select Best Mirror:** considers signed Ubuntu metadata and freshness before comparing small-file download rates.
- **Manual mirror choice:** ArvanCloud, IranServer, Pishgaman, or the official Ubuntu archive.
- **Security-first defaults:** `noble-security` (or your Ubuntu release's security pocket) stays on `security.ubuntu.com` unless you explicitly opt into `--all-mirror`.
- **Dry run, backups, and rollback:** preview changes; restore APT source files automatically if verification fails.
- **CLI-friendly:** explicit flags work in scripts and non-interactive environments.

## Quick start

Download the file first, then review it (recommended instead of piping a network response into Bash):

```bash
curl -fL -o setup-arvan-mirror.sh \
  https://raw.githubusercontent.com/ClassicDarkPack/arvan-mirror-setup/main/setup-arvan-mirror.sh

chmod +x setup-arvan-mirror.sh
less setup-arvan-mirror.sh
```

Run the interactive menu in a terminal or SSH session:

```bash
./setup-arvan-mirror.sh --menu
```

Or preview and apply the default Arvan configuration:

```bash
./setup-arvan-mirror.sh --dry-run
sudo ./setup-arvan-mirror.sh --apply
```

The menu previews changes and asks for confirmation before applying them. Actions that modify APT require root; the menu can invoke `sudo` when needed. Without arguments, the menu opens **only when both stdin and stdout are TTYs**. In automation, always use explicit flags.

### راهنمای سریع فارسی

این ابزار برای مدیریت میرورهای مخازن Ubuntu طراحی شده و روی سرورهای SSH هم منوی تعاملی دارد.

**نصب و اجرای منو:**

```bash
curl -fL -o setup-arvan-mirror.sh \
  https://raw.githubusercontent.com/ClassicDarkPack/arvan-mirror-setup/main/setup-arvan-mirror.sh
chmod +x setup-arvan-mirror.sh
./setup-arvan-mirror.sh --menu
```

**انتخاب خودکار بهترین میرور سالم و به‌روز:**

```bash
./setup-arvan-mirror.sh --check-mirrors
./setup-arvan-mirror.sh --auto --dry-run
sudo ./setup-arvan-mirror.sh --auto
```

**استفاده از پیشگامان یا میرور رسمی اوبونتو:**

```bash
sudo ./setup-arvan-mirror.sh --mirror pishgaman
sudo ./setup-arvan-mirror.sh --mirror ubuntu
```

**نکته امنیتی:** به‌صورت پیش‌فرض آپدیت‌های امنیتی از `security.ubuntu.com` دریافت می‌شوند. اگر می‌خواهید مخزن امنیتی هم از همان میرور انتخابی باشد، `--all-mirror` را آگاهانه اضافه کنید. اجرای مجدد بدون تغییر لازم، بکاپ جدید نمی‌سازد.

## Interactive menu

```text
========================================
       ARVAN MIRROR MANAGER
========================================
  1) Apply Arvan mirror (official security)
  2) Apply Arvan to all repositories
  3) Auto Select Best Mirror
  4) Check mirror freshness and speed
  5) List candidate mirror URLs
  6) Preview default changes (dry-run)
  7) Preview all-mirror changes
  8) Show APT source status
  9) Restore latest backup
 10) Help and options
 11) Exit
```

Menu text may change between releases. You can navigate with arrow keys and Enter, or use displayed numeric shortcuts. The interface is a terminal menu, not a desktop application.

## Supported mirrors

| Name | CLI selection | Ubuntu archive URL |
| --- | --- | --- |
| ArvanCloud | `--mirror arvan` | `https://mirror.arvancloud.ir/ubuntu` |
| IranServer | `--mirror iranserver` | `https://mirror.iranserver.com/ubuntu` |
| Pishgaman | `--mirror pishgaman` | `https://ubuntu.pishgaman.net/ubuntu` |
| Official Ubuntu | `--mirror ubuntu` | `https://archive.ubuntu.com/ubuntu` |

> [!NOTE]
> Listing a provider does **not** guarantee its availability or freshness for your Ubuntu release. Use `--check-mirrors` on the machine where you will install packages.

### How Auto Select works

1. Download the official Ubuntu `-updates/InRelease` metadata as a reference.
2. Verify Ubuntu archive signatures using `gpgv` and the system's Ubuntu archive keyring.
3. Check each candidate's signed `-updates` metadata date against the official reference. Reject candidates more than **12 hours behind**, or with invalid metadata.
4. Require signed metadata for the base and `-backports` pockets too. In `--all-mirror` mode, additionally check `-security` against the official security reference.
5. Choose the verified candidate with the highest measured download rate for its `-updates/InRelease` file.

**Important:** this is a lightweight metadata-speed comparison, **not** a complete package-download benchmark or a guarantee that every package is already synchronized. If the official signed reference cannot be verified, automatic selection stops without changing your sources. Manual selection is still available.

## Command reference

| Command | What it does |
| --- | --- |
| `./setup-arvan-mirror.sh --menu` | Open the terminal interface |
| `./setup-arvan-mirror.sh --list-mirrors` | List built-in URL candidates; no network check |
| `./setup-arvan-mirror.sh --check-mirrors` | Check mirror signatures, freshness, availability and metadata speed |
| `./setup-arvan-mirror.sh --auto --dry-run` | Preview changes using the best verified mirror |
| `sudo ./setup-arvan-mirror.sh --auto` | Select and apply the best verified mirror |
| `sudo ./setup-arvan-mirror.sh --mirror pishgaman` | Choose a named mirror manually |
| `sudo ./setup-arvan-mirror.sh --mirror ubuntu` | Switch standard Ubuntu sources to the official archive |
| `sudo ./setup-arvan-mirror.sh --mirror iranserver --all-mirror` | Also point the security pocket to the selected mirror |
| `./setup-arvan-mirror.sh --status` | Show managed sources and approximate Arvan references |
| `./setup-arvan-mirror.sh --dry-run` | Show proposed changes without writing them |
| `sudo ./setup-arvan-mirror.sh --restore` | Restore the latest backup and validate APT |
| `./setup-arvan-mirror.sh --help` | Show all flags |

Other examples:

```bash
sudo ./setup-arvan-mirror.sh --mirror https://example.org/ubuntu
./setup-arvan-mirror.sh --version
```

`--auto` cannot be combined with `--mirror`. The `--status` command reads source text; it is **not** a network-health test.

## Requirements

- **Ubuntu amd64** with `apt-get`, `awk` and standard GNU/Linux tools.
- `curl`, `gpgv` and the Ubuntu archive keyring (package `ubuntu-keyring`) for `--auto` and `--check-mirrors`.
- Internet access to mirrors **and the official Ubuntu reference** for automatic freshness checking.
- Root/sudo privileges for applying or restoring sources. You can preview and inspect sources without root.

ARM64 / Ubuntu ports are **not supported** in this release. The editor only manages `/etc/apt/sources.list` and `/etc/apt/sources.list.d/ubuntu.sources`; it deliberately avoids guessing about third-party repository files.

## Safety and limitations

> [!WARNING]
> Use caution on production machines. You are changing the package manager's repository endpoints, not just a download preference.

- Changes are restricted to recognized Ubuntu archive URLs/suites; unrelated APT stanzas, comments, `Signed-By`, `Architectures` and custom options are retained where supported.
- Unknown or multi-URI deb822 configurations are intentionally left unchanged. Other files in `sources.list.d` are not deduplicated or modified.
- Before each actual change, source files are backed up under `/var/backups/arvan-mirror-setup/`. A failed `apt-get update --error-on=any` triggers source-file rollback.
- Restoration uses the newest snapshot and validates APT again. Saved snapshots remain on disk until you remove them.
- APT package index caches are **not** rolled back; power failure or `SIGKILL` can interrupt automatic recovery.
- APT source validation can fail due to **unrelated third-party repositories**. An authenticated `InRelease` does not on its own prove every package file has synchronized.
- The default mode keeps the official Ubuntu security source. `--all-mirror` is an explicit trade-off that may expose you to security-mirror sync delays.
- Backups and rollback are safety measures, not a substitute for testing on a VM.

### Backups and troubleshooting

```bash
# Inspect your current managed sources
./setup-arvan-mirror.sh --status

# See planned changes with no writes
./setup-arvan-mirror.sh --dry-run

# Restore the latest pre-change sources snapshot
sudo ./setup-arvan-mirror.sh --restore

# Inspect locally stored snapshot directories
sudo ls -la /var/backups/arvan-mirror-setup/
```

If `--auto` reports that the official reference is unreachable, fix network access to the official archive or select a mirror manually. Do **not** treat an unverified mirror as fresh solely because its homepage opens.

## Testing and contributing

The test suite uses temporary files and a fake APT command, **not** your machine's real APT configuration.

```bash
bash -n setup-arvan-mirror.sh tests/test.sh
bash tests/test.sh

# Optional static analysis
shellcheck -S warning setup-arvan-mirror.sh tests/test.sh
```

[GitHub Actions](https://github.com/ClassicDarkPack/arvan-mirror-setup/actions) runs syntax checks, ShellCheck and integration tests for pushes and pull requests. Passing CI does not replace a real-world smoke test on a disposable Ubuntu VM.

Contributions are welcome. Open an [issue](https://github.com/ClassicDarkPack/arvan-mirror-setup/issues) with your Ubuntu codename, architecture, commands used, and **redacted** error output; or submit a pull request against `main`.

---

<div align="center">

Made for Ubuntu administrators who want **faster mirrors without giving up basic safety checks**.

[Repository](https://github.com/ClassicDarkPack/arvan-mirror-setup) · [Issues](https://github.com/ClassicDarkPack/arvan-mirror-setup/issues) · [Pull requests](https://github.com/ClassicDarkPack/arvan-mirror-setup/pulls)

</div>
