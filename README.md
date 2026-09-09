# kpi-sh

A shared library of composable shell functions for Klipper plugin installers.

kpi-sh is a single generated Bash file, `kpi.sh`, built from the modules
under `lib/`. It gives Klipper plugin authors a common, tested set of
primitives — safe symlinks, sentinel-delimited config blocks, systemd
restarts, atomic backups, Moonraker/Klipper discovery, and more — so that
every plugin installer doesn't reinvent (and re-break) the same handful of
shell idioms. It's aimed at anyone shipping a Klipper plugin with a shell
installer script, not end users.

The library requires **Bash 4.0+** and has no other runtime dependency
except Python 3, which is only needed lazily, the first time `json_get` is
called.

## Contract: safe under `set -eu`

kpi-sh is written to be **sourced by a consumer script running under `set
-eu`** (errexit + nounset) without surprises — that's the whole point of
using a shared library instead of copy-pasting shell snippets between
installers. Every function is expected to fail loudly via `die` (see
`log.sh` below) rather than let a consumer's script die silently or half
way through a mutation. The library itself does **not** set `-eu` (or any
other shell option) when sourced — that would change the consumer's own
shell options — so both example installers under `examples/` start with:

```bash
#!/bin/bash
set -eu
source "$(dirname "${BASH_SOURCE[0]}")/kpi.sh"
```

## Consumer integration

There are two ways to bring kpi-sh into your installer.

### Mode 1: source at runtime (vendored file)

Download `kpi.sh` and commit it alongside your own `install.sh`:

```bash
curl -fLO https://github.com/mjonuschat/kpi-sh/releases/download/v1.0.0/kpi.sh
git add kpi.sh && git commit -m "vendor kpi.sh v1.0.0"
```

Then source it from your installer:

```bash
#!/bin/bash
set -eu
source "$(dirname "${BASH_SOURCE[0]}")/kpi.sh"
# ... installer logic using kpi functions ...
```

To update, download the new release and commit over the old file.

### Mode 2: concatenate at build time

For single-file `curl | bash` distribution, concatenate `kpi.sh` in front
of your own installer logic at build time, e.g. in your `Makefile`:

```makefile
install.sh: kpi.sh installer.sh
	cat kpi.sh installer.sh > $@
	chmod +x $@
```

`installer.sh` itself has no shebang and no `source` line — it assumes the
kpi functions already exist above it in the concatenated file. You're
responsible for putting `set -eu` at the top of `installer.sh` if you want
it (kpi.sh never sets it for you). The sentinel comments wrapping the
library block (`# --- kpi.sh v1.0.0 ---` / `# --- /kpi.sh ---`) let you
locate and replace the library block programmatically on version bumps.

### Checksum verification

Every tagged release attaches `kpi.sh.sha256` next to `kpi.sh` as a GitHub
Release asset (produced locally via `make checksum`). Verify a download
with:

```bash
sha256sum -c kpi.sh.sha256
```

### Trust model

Neither integration mode implements cryptographic authenticity — that's an
explicit, accepted scope limit, not an oversight. `kpi.sh.sha256` detects
transport corruption or an unintentionally stale mirror; it does **not**
protect against a compromised GitHub release, repo, or CDN, since an
attacker able to replace the artifact can replace the checksum file right
next to it. Two consequences follow:

- **Mode 1 (vendoring) is the higher-trust path.** The downloaded `kpi.sh`
  is committed into your own repo and code-reviewed like any other vendored
  dependency — your repo history is the audit trail.
- **Mode 2 (`curl | bash` at install time) is a lower-trust convenience
  path** that requires the installing user to trust GitHub's release
  infrastructure at the moment of install, same as most `curl | bash`
  installers. This is documented, not solved.

Two functions in particular have their own narrower trust boundaries worth
knowing about:

- `git_ensure_clone` trusts `repo_url` and `ref` as given by the caller —
  it validates that an *existing* checkout's origin matches the expected
  URL and that a validator file exists after checkout, but it does not
  verify the content of a fresh clone or checkout against anything beyond
  that.
- `klipper.sh`'s Moonraker discovery (`discover_klipper_env`,
  `moonraker_query`, `check_no_active_print`) treats Moonraker's HTTP
  responses as trusted local input — any host at `$MOONRAKER_HOST`, default
  or explicitly overridden, is trusted to answer honestly. Discovered
  filesystem paths are still constrained under `$HOME` and validated by
  identity (e.g. `klippy/klippy.py` must exist) before use; an explicitly
  set `$MOONRAKER_HOST` bypasses none of that path validation, only the
  "is this the default host" bookkeeping.

## Function reference

One line per public function, grouped by the `lib/*.sh` module it lives in
(this is also the concatenation order used to build `kpi.sh`).

### `header.sh` — Library Init

Sourced first. Sets `LC_ALL=C`, enforces the Bash 4.0+ floor, and
lazily reserves an interactive input fd for `prompt.sh`. Exposes no public
functions of its own.

### `log.sh` — Logging

- `log MESSAGE` — write a message to stderr (stdout is reserved for return
  data across the whole library).
- `err MESSAGE` — write `error: MESSAGE` to stderr.
- `die MESSAGE` — `err MESSAGE` then `exit 1`.

### `path.sh` — Path Utilities

- `abspath PATH` — purely lexical absolute-path normalization (never
  follows symlinks; collapses `.`/`..`).
- `script_dir` — the absolute directory of the top-level entrypoint script
  (walks `BASH_SOURCE` to the outermost frame).

### `symlink.sh` — Safe Symlink Management

- `classify_path PATH` — prints `absent`, `real`, or `symlink`.
- `remove_safe_link PATH` — removes `PATH` only if it's a symlink;
  refuses (returns 1) on a real file.
- `link_safe [--allow-dangling] TARGET LINK_NAME` — creates/replaces a
  symlink at `LINK_NAME`, refusing to clobber a real file; creates
  `LINK_NAME`'s parent directory if needed.

### `preflight.sh` — Preflight Checks

- `require_not_root` — dies if `$EUID` is 0 (no override of any kind).
- `require_systemd_service NAME` — dies if the systemd unit isn't
  installed.
- `require_python_min INTERPRETER MAJOR MINOR` — dies if `INTERPRETER`'s
  Python version is below `MAJOR.MINOR`.

### `json.sh` — JSON Parsing

- `json_get [KEY...]` — reads JSON from stdin, prints the value at the
  given key path (scalar only), returns 1 if the path doesn't resolve to a
  scalar, dies on malformed input. Lazily autodetects `python3`/`python` on
  first call.

### `git.sh` — Git Repository Management

- `git_ensure_clone REPO_URL DEST [VALIDATOR] [REF]` — clones `REPO_URL`
  into `DEST` if absent, otherwise verifies an existing checkout's origin
  matches; optionally checks out `REF` (tag/branch/SHA) and/or verifies a
  `VALIDATOR` file exists afterward. Never fetches/pulls an
  already-valid existing checkout.

### `config_block.sh` — Sentinel-Delimited Config Blocks

- `config_block_add FILE NAME CONTENT` — appends a new
  `# --- NAME ---`/`# --- /NAME ---` block; no-ops if it already exists.
- `config_block_ensure FILE NAME CONTENT` — like `config_block_add`, but
  also creates `FILE` if it doesn't exist yet.
- `config_block_remove FILE NAME` — removes the named block; no-ops if
  absent, dies on malformed/foreign-sentinel content. All writes are
  atomic (temp file + rename).

### `service.sh` — Systemd Service Management

- `service_restart_if SERVICE [PREDICATE]` — restarts `SERVICE` via
  `sudo systemctl restart` (30s timeout) unless `PREDICATE` declines; dies
  on timeout or restart failure.

### `backup.sh` — Config Backup

- `backup_dir_timestamped SOURCE BACKUP_ROOT` — copies `SOURCE` into a
  timestamped directory under `BACKUP_ROOT` via stage-then-rename, and
  prints the final path. Designed to be called as
  `dir="$(backup_dir_timestamped ...)"`.
- `backup_scrub_symlinks BACKUP_DIR PREFIX` — removes symlinks inside
  `BACKUP_DIR` that resolve under `PREFIX` (dangling symlinks are left
  untouched).

### `prompt.sh` — Interactive Prompts

- `confirm_yn PROMPT [DEFAULT]` — y/n prompt with bounded retry (3
  attempts); falls back to `DEFAULT` on EOF or a non-interactive
  environment; never blocks forever.
- `select_from_dir PROMPT DIR GLOB` — lists files matching `GLOB` in `DIR`
  and prompts for a selection, printing the chosen path; returns 1 on
  skip/no-match/no-tty.

### `version.sh` — Version Tracking

- `version_stamp REPO_DIR DEST_FILE` — writes `REPO_DIR`'s current HEAD
  SHA into `DEST_FILE` atomically, preserving permissions.
- `is_first_install DEST_FILE` — true if `DEST_FILE` does not exist yet.

### `klipper.sh` — Klipper Ecosystem

- `moonraker_query ENDPOINT` — GETs `${MOONRAKER_HOST}ENDPOINT` from
  Moonraker (8s timeout, 1MiB response cap).
- `discover_klipper_env` — populates `MOONRAKER_HOST`, `KLIPPER_PATH`,
  `KLIPPY_PYTHON`, `KLIPPER_PLUGINS_PATH`, and `MOONRAKER_CONFIG` from
  Moonraker (when reachable) or hardcoded defaults under `$HOME`, without
  overwriting any of those variables the caller already set.
- `check_no_active_print` — returns 0 if Klipper reports no active print
  (or is unreachable), 1 otherwise.

## Building and testing

```bash
make kpi.sh          # build the concatenated library
make checksum        # build kpi.sh and kpi.sh.sha256
make test            # full bats suite (unit + integration)
make test-unit       # unit tests only
make test-integration
make shellcheck      # shellcheck on every lib/*.sh module
```

## License

Dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at
your option.
