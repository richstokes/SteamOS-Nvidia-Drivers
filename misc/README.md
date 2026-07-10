# SteamOS remote helpers

These Bash scripts run on your Mac or Linux machine and connect to SteamOS over
SSH. They are self-contained and are not required by the main project.

Set the connection values once per shell session if convenient:

```bash
export STEAMOS_HOST=192.168.1.75
export STEAMOS_USER=steamosadmin
```

## Back up a home directory

```bash
./backup-steamos-home.sh
```

The default source is `/home/deck`. The backup is a dated
`steamos-deck-home-YYYYMMDD-HHMMSS.zip` on your Desktop. SteamOS creates the
ZIP and streams it directly to the host, so a large temporary copy is not left
on SteamOS. Before beginning, the script checks the host has at least the
source's current disk usage plus 5% free.

Add `--dry-run` to exercise the SSH, sudo, and capacity checks without
creating an archive.

By default, timestamped `dot-steam.bak.*` directories are excluded. These are
usually obsolete Steam migration backups, while the active Steam paths are
included. To retain them deliberately, pass `--include-dot-steam-backups`.

Use `--remote-home` for another direct child of `/home`, and `--output-dir`
to choose a different local destination. The script validates the completed ZIP
and prints its SHA-256.

## Restore a backup

After installing SteamOS and creating the target account again:

```bash
./restore-steamos-home.sh ~/Desktop/steamos-deck-home-20260710-120000.zip
```

The script validates the archive locally, rejects path-traversal paths, checks
SteamOS has enough space, uploads it, validates it again there, and extracts it
to `/home/deck`.

The default mode safely merges into the existing home. For a fresh SteamOS
installation, use `--replace`:

```bash
./restore-steamos-home.sh --replace ~/Desktop/steamos-deck-home-20260710-120000.zip
```

`--replace` moves the prior directory to a timestamped
`/home/.deck.pre-restore-*` name rather than deleting it. After confirming the
restore, remove that directory manually to reclaim space. Do not restore while
the target account is running Steam, Desktop Mode, or other applications.

ZIP is chosen because it is easy to carry between machines. It preserves files,
hidden files, and symlinks, but not Linux ownership, ACLs, extended attributes,
or hard links. Restore normalizes ownership to the account that owns the target
home.

## Inspect A/B slot and update state

```bash
./steamos-slot-status.sh
```

This read-only report includes RAUC's active/inactive root and verity slots and
their health, SteamOS boot configuration, update-channel metadata, important
mounts/partitions, and boot-loader data. It never marks a slot good/bad or
changes boot configuration.

## Enable GameMode's CPU governor helper

```bash
./enable-steamos-gamemode-governor.sh
```

SteamOS includes GameMode but its default Polkit policy denies its privileged
CPU-governor helper. This optional helper grants the `deck` session access to
that one GameMode action, so games launched with `gamemoderun %command%` can
temporarily use the performance governor. It does not grant general `pkexec`
or administrator access, and it leaves GameMode's other privileged helpers
denied.

It writes its own atomic-update keep-list so SteamOS A/B updates retain the
authorization. Use `--remove` to undo it, then fully relaunch any running game.

## Sudo and SSH

Backup and restore need SteamOS sudo access to reliably read and write a home
directory. They use passwordless sudo when configured; otherwise they prompt
once for the remote sudo password without echoing it. SSH may also prompt for
its normal password or key passphrase.

All scripts accept `--host` and `--user`; run `./<script> --help` for the
full option list.
