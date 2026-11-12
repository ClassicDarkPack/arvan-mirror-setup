# Arvan Mirror Setup

A cautious Bash utility for switching **Ubuntu amd64** APT sources to the [ArvanCloud](https://www.arvancloud.ir/) mirror. It supports the legacy `sources.list` format and Ubuntu's newer deb822 `ubuntu.sources` format.

Unlike the original installer, it **edits recognized Ubuntu entries instead of replacing entire source files**. It backs up changed files and automatically restores them if APT validation fails.

## Features

- Detects Ubuntu and its codename using `/etc/os-release`; refuses Debian and unsupported CPU architectures.
- Changes only recognized official Ubuntu / Arvan repository URLs in:
  - `/etc/apt/sources.list`
  - `/etc/apt/sources.list.d/ubuntu.sources`
- Preserves third-party entries, comments, `Components`, `Signed-By`, `Architectures`, and other deb822 fields.
- **Keeps Ubuntu security updates on the official security server by default.** Use `--all-mirror` to put them on Arvan too. For older installs that put normal and security suites in one deb822 stanza, separates them as necessary.
- Creates a timestamped, permission-restricted backup under `/var/backups/arvan-mirror-setup/` whenever files change.
- Automatically rolls back source files when `apt-get update --error-on=any` fails, including when APT cannot reach another enabled repository.
- Supports preview (`--dry-run`), inspection (`--status`), restoration (`--restore`), and custom HTTPS mirror (`--mirror`).
- Running it a second time without any pending changes does not create more backups or run APT again.

## Requirements

- Ubuntu **amd64** with `apt-get`, `awk`, and standard GNU/Linux utilities.
- `sudo`/root access for `--apply` (default) and `--restore`.
- Network access to the configured mirror and enabled APT repositories during validation.

> This version deliberately **does not support arm64/Ubuntu ports** because availability of the matching mirror layout has not been verified. Other `.list`/`.sources` files under `sources.list.d/` are left untouched rather than guessing which sources should be changed.

## Install and use

**Download and review the script before running it** (recommended over `curl | bash`):

```bash
curl -fL -o setup-arvan-mirror.sh \
  https://raw.githubusercontent.com/ClassicDarkPack/arvan-mirror-setup/main/setup-arvan-mirror.sh
chmod +x setup-arvan-mirror.sh
less setup-arvan-mirror.sh
```

Preview without elevated privileges (the preview does not change APT configuration):

```bash
./setup-arvan-mirror.sh --dry-run
```

Apply and validate:

```bash
sudo ./setup-arvan-mirror.sh --apply
```

Other options:

```bash
./setup-arvan-mirror.sh --status
sudo ./setup-arvan-mirror.sh --restore
sudo ./setup-arvan-mirror.sh --all-mirror
sudo ./setup-arvan-mirror.sh --mirror https://example.org/ubuntu
./setup-arvan-mirror.sh --help
```

`--all-mirror` includes `-security` sources; without it, an existing official security URL remains unchanged. If previous versions redirected security updates to Arvan, the default mode switches those sources back to `https://security.ubuntu.com/ubuntu/`.

`--restore` restores the **latest snapshot**, then runs `apt-get update` to verify it. It also protects the pre-restore state in case validation fails. Backups remain on disk until an administrator removes them.

## Safety and limitations

- **Review the `--dry-run` diff before applying** on machines with customized APT settings.
- Changes are limited to recognized Ubuntu codenames/suites (`codename`, `-updates`, `-backports`, `-security`), and known official Ubuntu or Arvan repository URLs. Unknown source layouts or multi-URI deb822 stanzas are not modified.
- APT source configurations may already contain duplicate entries in other files. This tool does not disable or deduplicate third-party or unmanaged files.
- Validation fails on **any** `apt-get update` error, including errors caused by unrelated third-party repositories, and restores the previous source files. The `apt-get` package index cache itself is not rolled back.
- Backups are local, and automatic rollback cannot protect against an abrupt power loss or `SIGKILL`. Recovery remains possible from the stored snapshots.
- Default URL: `https://mirror.arvancloud.ir/ubuntu/`. Actual mirror availability and freshness depend on the service provider. Security updates are deliberately kept on their official origin unless opted in.
- `--status` lists source files and approximate active references; it is **not** a network/health check.

## Testing

The integration tests run entirely in temporary directories with a fake `apt-get` command, so they never modify real system sources:

```bash
bash -n setup-arvan-mirror.sh
bash tests/test.sh
# Optional: shellcheck setup-arvan-mirror.sh tests/test.sh
```

GitHub Actions runs the syntax check, ShellCheck, and tests on pushes and pull requests. Tests do not prove the actual Arvan network endpoint is accessible from every location; test on a disposable Ubuntu VM before using in production.
