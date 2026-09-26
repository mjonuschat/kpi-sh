# kpi-sh

Shell functions for Klipper plugin installers.

Most Klipper plugins ship an `install.sh` that does the same few jobs. It
links files into Klipper, adds an `[update_manager]` block to
`moonraker.conf`, and restarts Klipper. Each author writes these from
scratch, and the same bugs keep coming back. Installers overwrite real
files with symlinks, leave stale config blocks behind, and restart Klipper
mid-print. kpi-sh does these jobs once, with tests, so your installer can
call a function instead.

The library is one generated Bash file, `kpi.sh`, built from the modules in
`lib/`. It's meant for plugin authors, not end users.

It needs Bash 4.0 or newer. The only other runtime dependency is Python 3,
and only `json_get` uses it. The library looks for Python the first time
`json_get` runs, not when you source it.

## Safe under `set -eu`

Source kpi-sh from a script running under `set -eu`. Every function checks
its own commands and calls `die` when something fails, so your installer
stops with an error message instead of carrying on after a half-finished
change. This also holds when you call a function as an `if` condition or on
the left of `&&` or `||`, where bash turns `set -e` off.

The library never changes your shell options or your locale. Turn on
`set -eu` yourself. Both example installers in `examples/` start like this:

```bash
#!/bin/bash
set -eu
source "$(dirname "${BASH_SOURCE[0]}")/kpi.sh"
```

## Using it in your installer

You can vendor the file or concatenate it into your installer at build
time.

### Mode 1: vendor the file

Download `kpi.sh` and commit it next to your `install.sh`:

```bash
curl -fLO https://github.com/mjonuschat/kpi-sh/releases/download/v1.0.0/kpi.sh
git add kpi.sh && git commit -m "vendor kpi.sh v1.0.0"
```

Then source it:

```bash
#!/bin/bash
set -eu
source "$(dirname "${BASH_SOURCE[0]}")/kpi.sh"
# your installer logic
```

To update, download the new release over the old file and commit it.

### Mode 2: concatenate at build time

If your users install with `curl | bash`, the installer has to be a single
file. Put `kpi.sh` in front of your own code at build time, for example in
your `Makefile`:

```makefile
install.sh: kpi.sh installer.sh
	cat kpi.sh installer.sh > $@
	chmod +x $@
```

`installer.sh` has no shebang and no `source` line, because the kpi
functions already sit above it in the combined file. Put `set -eu` at the
top of `installer.sh` if you want it. The library block starts with
`# --- kpi.sh v1.0.0 ---` and ends with `# --- /kpi.sh ---`, so a script can
find and replace it when you upgrade.

### Checksums

Each release on GitHub includes `kpi.sh.sha256` next to `kpi.sh`. Check a
download with:

```bash
sha256sum -c kpi.sh.sha256
```

### Trust model

Neither mode proves that the file came from me. The checksum catches a
corrupted download or a stale mirror. It misses a compromised GitHub
release, because whoever can replace `kpi.sh` can replace the checksum file
next to it. I accept that limit on purpose. It has two consequences.

- Mode 1 is the safer path. The file lives in your repo, you review it like
  any other vendored dependency, and your git history records every change.
- Mode 2 asks the person running `curl | bash` to trust GitHub's release
  hosting at that moment, as every `curl | bash` installer does. No code
  change can fix that.

Two functions draw their own trust lines.

- `git_ensure_clone` trusts the `repo_url` and `ref` you pass. For an
  existing checkout it checks that `origin` matches, and after checkout it
  checks that the validator file exists. A fresh clone gets no further
  checks.
- `discover_klipper_env`, `moonraker_query`, and `check_no_active_print`
  trust whatever answers at `$MOONRAKER_HOST`. Paths that Moonraker reports
  must still resolve under `$HOME` and look like the real thing, so
  `klippy/klippy.py` has to exist in the Klipper path. Pointing
  `MOONRAKER_HOST` at another host prints a warning, and every path check
  still applies.

## Function reference

Modules are listed in the order `make` concatenates them into `kpi.sh`.

### `header.sh`, library init

Checks for Bash 4.0 or newer. If fd 9 is free, it opens `/dev/tty` on fd 9
so prompts still work under `curl | bash`. It defines no public functions.

### `log.sh`, logging

Stdout carries return values only. All log output goes to stderr.

- `log MESSAGE` writes `MESSAGE` to stderr.
- `err MESSAGE` writes `error: MESSAGE` to stderr.
- `die MESSAGE` calls `err MESSAGE`, then `exit 1`.

### `path.sh`, path utilities

- `abspath PATH` makes `PATH` absolute and collapses `.` and `..` without
  touching the filesystem. It doesn't follow symlinks.
- `script_dir` prints the directory of the top-level script, even when
  called from a sourced file.

### `symlink.sh`, symlinks

- `classify_path PATH` prints `absent`, `real`, or `symlink`.
- `remove_safe_link PATH` removes `PATH` if it's a symlink. It returns 0
  when `PATH` is already gone, 1 when `PATH` is a real file it refuses to
  touch, and 2 when removal fails.
- `link_safe [--allow-dangling] TARGET LINK_NAME` creates or replaces the
  symlink at `LINK_NAME` and creates its parent directory if needed. It
  refuses to replace a real file. It converts `TARGET` to an absolute
  path, so every link it makes is absolute. Without `--allow-dangling` it
  dies if `TARGET` doesn't exist.

### `preflight.sh`, preflight checks

- `require_not_root` dies if `$EUID` is 0. There's no override.
- `require_systemd_service NAME` dies if the systemd unit isn't installed.
- `require_python_min INTERPRETER MAJOR MINOR` dies if `INTERPRETER` is
  older than Python `MAJOR.MINOR`.

### `json.sh`, JSON parsing

- `json_get [KEY...]` reads JSON on stdin and prints the scalar at the key
  path. It returns 1 if the path is missing or points at an object or
  array, and dies on malformed JSON. The first call finds `python3` or
  `python`.

### `git.sh`, git checkouts

- `git_ensure_clone REPO_URL DEST [VALIDATOR] [REF]` clones `REPO_URL` into
  `DEST` if `DEST` is missing or empty. If `DEST` is already a checkout, it
  dies unless `origin` matches `REPO_URL`. With `REF` it checks out that
  tag, branch, or commit. With `VALIDATOR` it dies if that file is missing
  afterwards. It never pulls an existing checkout, because updates are
  Moonraker's job.

### `config_block.sh`, config blocks

Blocks start with `# --- NAME ---` and end with `# --- /NAME ---`. All
writes go to a temp file first and replace the original with a rename.

- `config_block_add FILE NAME CONTENT` appends the block to `FILE`. If a
  block with that name exists, it replaces the content in place and leaves
  the file untouched when nothing changed, so a reinstall with a new path
  or origin updates the config. It dies if `FILE` doesn't exist, since a
  missing `moonraker.conf` means the install is broken.
- `config_block_ensure FILE NAME CONTENT` works like `config_block_add` but
  creates `FILE` when it's missing.
- `config_block_remove FILE NAME` removes the block. It does nothing if the
  file or block is missing, and dies if the block has no end marker or
  contains another block's marker.

### `service.sh`, systemd services

- `service_restart_if SERVICE [PREDICATE]` runs
  `sudo systemctl restart SERVICE` with a 30 second timeout. If you pass
  `PREDICATE` and it fails, the function logs a notice and skips the
  restart. It dies on a timeout or a failed restart.

### `backup.sh`, config backups

- `backup_dir_timestamped SOURCE BACKUP_ROOT` copies `SOURCE` into a new
  timestamped directory under `BACKUP_ROOT` and prints its path. It copies
  into a hidden staging directory first and renames it when the copy is
  done, so an interrupted backup never looks complete. Call it as
  `dir="$(backup_dir_timestamped ...)"`.
- `backup_scrub_symlinks BACKUP_DIR PREFIX` deletes absolute symlinks in
  `BACKUP_DIR` that point to `PREFIX` or anything under `PREFIX/`. It
  keeps relative links, dangling links, and links to a sibling such as
  `${PREFIX}_old`.

### `prompt.sh`, prompts

- `confirm_yn PROMPT [DEFAULT]` asks a yes/no question and gives up after
  three invalid answers. On EOF, with no terminal, or after three bad
  answers, it uses `DEFAULT`, or dies if you gave none.
- `select_from_dir PROMPT DIR GLOB` shows a numbered menu of the files in
  `DIR` that match `GLOB` and prints the path the user picks. It returns 1
  when the user skips, nothing matches, or there's no terminal.

### `version.sh`, install tracking

- `version_stamp REPO_DIR DEST_FILE` writes the commit hash of `REPO_DIR`'s
  HEAD to `DEST_FILE`. It replaces the file atomically and keeps its
  permissions.
- `is_first_install DEST_FILE` succeeds if `DEST_FILE` doesn't exist yet.

### `klipper.sh`, Klipper and Moonraker

- `moonraker_query ENDPOINT` fetches `${MOONRAKER_HOST}ENDPOINT` with an 8
  second timeout and a 1 MiB size limit, prints the body, and returns
  curl's exit code.
- `discover_klipper_env` sets `MOONRAKER_HOST`, `KLIPPER_PATH`,
  `KLIPPY_PYTHON`, `KLIPPER_PLUGINS_PATH`, and `MOONRAKER_CONFIG`. It asks
  Moonraker first and falls back to the standard paths under `$HOME`. A
  variable you set before calling it stays as you set it.
- `check_no_active_print` succeeds only when Klipper reports `standby`,
  `complete`, `cancelled`, or `error`. Any other state fails, and so does
  an unreachable Moonraker or a missing field. If the function can't tell
  whether a print is running, it assumes one is, so nothing restarts
  Klipper mid-print by accident.

## Building and testing

```bash
make kpi.sh          # build dist/kpi.sh
make checksum        # also write dist/kpi.sh.sha256
make test            # all bats tests, unit and integration
make test-unit       # unit tests only
make test-integration
make shellcheck      # shellcheck every lib/*.sh module
```

## License

Dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at
your option.
