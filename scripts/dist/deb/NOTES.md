# Debian Package (.deb)

Fixed install path: `/opt/dispatcharr/`. Everything self-contained under that prefix with no FHS split across `/etc/`, `/var/lib/`, or `/usr/`.

## How the deb is built

CI workflow (`.github/workflows/dist.yml`):

1. Export the Docker image to a rootfs tarball (`docker export`).
2. Extract binaries from the rootfs: postgres, pg_ctl, initdb, pg_dump, pg_isready,
   createdb, createuser, psql, pg_upgrade, redis-server, redis-cli, nginx, ffmpeg, ffprobe.
   Also collect non-glibc .so dependencies via `readelf` + `find`.
3. Download Python Build Standalone 3.13. Compile a uwsgi wheel in CI (no binary wheel
   exists for CPython 3.13 on PyPI), then download remaining wheels with pip.
4. Copy app code from rootfs. `frontend/dist` is present (built during image build);
   `app/static/` is empty (collectstatic runs at container startup, not build time).
   postinst runs collectstatic after pip install.

   Steps 1-4 are common to all package types. The following are deb-specific:

5. Generate deb configs from Docker sources via sed transforms (see Config sources below).
6. Build the .deb with nfpm. nfpm auto-adds `/opt/` as an implicit parent directory entry;
   this causes `dpkg` to print a harmless warning on removal ("directory '/opt' not empty
   so not removed") since /opt/ is a system directory we do not own. This is accepted
   behavior consistent with other /opt/ packages (VS Code, Chrome, Slack).

## Config sources

Docker files are the source of truth for nginx and uwsgi config. The deb versions are
generated at CI time via sed transforms that substitute Docker-relative paths and ports
for the fixed `/opt/dispatcharr/` layout.

| File | Source |
|---|---|
| `config.defaults/nginx.conf` | Generated: `nginx-http-header.conf` + `docker/nginx.conf` through sed transforms + closing `}` |
| `config.defaults/uwsgi.ini` | Generated: `docker/uwsgi.ini` through sed transforms |
| `config.defaults/redis.conf` | Static: no Docker equivalent |
| `config.defaults/dispatcharr.env` | Static: no Docker equivalent |

When `docker/nginx.conf` or `docker/uwsgi.ini` changes, review the sed transforms
in the "Generate configs from Docker sources" step to confirm all new paths, ports,
and directives are covered.

## Install and upgrade flow

preinst receives `upgrade <old-version>` before dpkg replaces files (snapshots PG binaries for pg_upgrade).
postinst receives `configure <old-version>` on upgrade and `configure` (no second arg) on first install.

**First install:**

1. Create system user `dispatcharr` (nologin).
2. Create data directories under `/opt/dispatcharr/data/`.
3. Copy `config.defaults/` to `config/` (user config, preserved on upgrade).
4. Generate Django secret key.
5. Create Python venv from bundled wheels.
6. Run `collectstatic` to populate `app/static/` from `frontend/dist`.
7. Run `initdb`, configure PostgreSQL (port, TCP loopback, socket dir).
8. Start PostgreSQL, run migrations, stop PostgreSQL.
9. Enable and start the systemd service.

**Upgrade:**

1. Update venv from new wheels.
2. Run `collectstatic` (picks up any new frontend assets).
3. Stop the service.
4. If the bundled PostgreSQL major version changed: run `pg_upgrade` automatically.
   preinst saved the old binaries and share dir to `.pg-upgrade-old/` before dpkg
   replaced them; postinst initializes a new cluster, runs `pg_upgrade`, and swaps
   the data directories. The old cluster is preserved as `data/db.old-<ver>` and
   can be deleted manually after verifying the upgrade.
5. Start PostgreSQL, run migrations, stop PostgreSQL.
6. Start the service.

## Directory layout

```
/opt/dispatcharr/
  dispatcharr         launcher script (start/stop/restart/status/logs/backup)
  bin/                bundled system binaries (postgres, nginx, redis, ffmpeg, ...)
  lib/                bundled .so dependencies
  python/             Python Build Standalone 3.13
  wheels/             pre-downloaded Python wheels (offline venv install)
  requirements.txt    fully pinned dependency list (compiled from pyproject.toml)
  app/                Django application code + pre-built frontend (frontend/dist)
  etc/nginx/          nginx support files (mime.types, uwsgi_params, ...)
  share/postgresql/   PostgreSQL share files (postgres.bki, timezones, ...)
  config.defaults/    default configs shipped with the deb (read-only reference)
  config/             active user config (copied from config.defaults on first install)
  venv/               Python virtualenv (created by postinst, not tracked by dpkg)
  data/               persistent user data: db, logs, media (not tracked by dpkg)
  run/                PID files and sockets (runtime only)
```

## Upgrade checklist for dependency bumps

**PostgreSQL major version (e.g., 17 to 18)**

One line to update in `dist.yml`, "Extract binaries":
```
PG_BIN="rootfs/usr/lib/postgresql/17/bin"
```
Change `17` to the new major version. Everything else is automatic: the `find` for
extension `.so` files has no version number; PG_VER detection in postinst and prerm
reads the bundled share dir at runtime; pg_upgrade for existing deb installs is handled
by preinst/postinst. Document the version bump in release notes for non-deb installs.

---

**Python minor version (e.g., 3.13 to 3.14)**

One pattern to update in `dist.yml`, "Bundle Python and wheels":
```
grep "cpython-3\.13"
```
Change `3\.13` to the new version. All wheels are re-downloaded by CI against the new
interpreter automatically; no other changes needed.

---

**New nginx location or directive in `docker/nginx.conf`**

In `dist.yml`, "Generate configs from Docker sources", nginx sed block (the block that
appends to `pkg/config.defaults/nginx.conf`): add a new expression for any new
Docker-relative path or port:
```
-e 's|old-docker-path|/opt/dispatcharr/new-path|g'
```

---

**New uwsgi attach-daemon in `docker/uwsgi.ini`**

In `dist.yml`, "Generate configs from Docker sources", uwsgi sed block: add an expression
to rewrite the command path for the deb layout:
```
-e 's|attach-daemon = <cmd>|attach-daemon = /opt/dispatcharr/venv/bin/python -m <cmd>|g'
```
If the daemon is removed entirely for the deb build (as redis is), also add:
```
-e '/attach-daemon = <cmd>/d'
-e '/<comment line above it>/d'
```

---

**New uwsgi exec-pre in `docker/uwsgi.ini`**

No change needed: `-e '/exec-pre/d'` in the uwsgi sed block removes all exec-pre lines
automatically. If the new exec-pre has a comment immediately above it, also add:
```
-e '/<phrase from that comment>/d'
```

---

## Next steps: apt repository

Currently the `.deb` is only available as a GitHub Releases artifact, requiring a manual
`dpkg -i`. To support `apt install dispatcharr` and `apt upgrade`, the project needs a
signed apt repository.

**Approach: index files uploaded alongside each release**

GitHub's `releases/latest/download/<file>` URL always resolves to the latest release
asset with that name. apt follows redirects, so this URL works as a stable apt base
with no dedicated branch or tag required.

The `publish-apt-repo` job in `dist.yml` (currently disabled) runs after `build-deb`
on every release and uploads five files to the same release:

- `Packages` / `Packages.gz` - generated by `dpkg-scanpackages` from both arch `.deb`s
- `Release` / `InRelease` / `Release.gpg` - generated by `apt-ftparchive` and signed
  with the GPG key stored as `APT_GPG_PRIVATE_KEY` in Actions secrets

The user source line never changes across releases:
```
curl -fsSL \
  https://github.com/Dispatcharr/Dispatcharr/releases/latest/download/key.gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/dispatcharr.gpg
echo "deb [signed-by=/etc/apt/keyrings/dispatcharr.gpg] \
  https://github.com/Dispatcharr/Dispatcharr/releases/latest/download/ ./" \
  | sudo tee /etc/apt/sources.list.d/dispatcharr.list
sudo apt update && sudo apt install dispatcharr
```

**To enable:**

1. Generate a GPG signing key into a temporary keyring (does not touch your personal keyring):
   ```bash
   GNUPGHOME=$(mktemp -d)
   gpg --homedir "$GNUPGHOME" --batch --gen-key <<EOF
   %no-protection
   Key-Type: RSA
   Key-Length: 4096
   Name-Real: Dispatcharr Apt Repo
   Name-Email: apt@dispatcharr.tv
   Expire-Date: 0
   %commit
   EOF
   gpg --homedir "$GNUPGHOME" --batch --export-secret-keys --armor
   rm -rf "$GNUPGHOME"
   ```
   Copy the `--export-secret-keys` output as the value of the `APT_GPG_PRIVATE_KEY` secret.
2. Export the private key and store it as `APT_GPG_PRIVATE_KEY` in repo Actions secrets.
3. Remove the `if: false` line from the `publish-apt-repo` job in `dist.yml`.
