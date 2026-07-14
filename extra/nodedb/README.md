# Oxidized sqlite node inventory + web UI

Replaces the semicolon-delimited `router.db` (plaintext credentials per line)
with:

- an **sqlite database** read by Oxidized's built-in SQL source,
- **shared credentials in the oxidized config** (chmod 600) instead of
  per-device plaintext secrets — the database itself contains no secrets
  unless a device genuinely needs an override,
- a **small Sinatra UI** (`app.rb`) to add/edit/delete nodes, which pokes
  oxidized-web's `/reload` endpoint so changes apply immediately.

## 1a. Install — Docker (the normal prod setup)

Nothing to install by hand: the image built from this repository's Dockerfile
already contains the SQL source dependencies (`ruby-sequel`, `ruby-sqlite3`)
and ships this UI at `/opt/nodedb` behind a runit service that only starts
when the container gets `NODEDB_UI=true`.

Build for the prod architecture, tag and push:

```sh
docker buildx build --platform linux/amd64 \
  -t <registry>/oxidized-custom:<newtag> --push .
```

Run with an extra volume for the database and the UI enabled:

```sh
docker run -d --name oxidized \
  -v /data/oxidized/config:/home/oxidized/.config/oxidized \
  -v /data/oxidized/nodedb:/home/oxidized/nodedb \
  -v /data/oxidized/backups:/home/oxidized/backups \
  -e NODEDB_UI=true \
  -e NODEDB_UI_PASSWORD=<pick-one> \
  -p 8888:8888 -p 8889:8889 \
  <registry>/oxidized-custom:<newtag>
```

(Keep your existing volumes/env as-is and just add the `nodedb` volume, the
two `NODEDB_UI*` variables and port 8889. The old `routerdb` volume stays
mounted until the migration below is done and verified.)

## 1b. Install — bare metal (no Docker)

As the `oxidized` user on the backup host:

```sh
mkdir -p /home/oxidized/nodedb
cp schema.sql migrate_routerdb.rb app.rb Gemfile /home/oxidized/nodedb/
cd /home/oxidized/nodedb
bundle install          # sequel, sqlite3, sinatra, puma
```

(`libsqlite3-dev` and `build-essential` may be needed for the sqlite3 gem:
`apt-get install libsqlite3-dev build-essential`.)

## 2. Migrate router.db

Docker — run the bundled script inside the container:

```sh
docker exec -it oxidized gosu oxidized ruby /opt/nodedb/migrate_routerdb.rb \
  /home/oxidized/routerdb/router.db /home/oxidized/nodedb/nodes.db
```

Bare metal:

```sh
cd /home/oxidized/nodedb
bundle exec ruby migrate_routerdb.rb /home/oxidized/routerdb/router.db nodes.db
chmod 640 nodes.db
```

The script imports name/ip/model/group/ssh_port and prints the **distinct
credential sets** it found per group — copy those into the oxidized config
(next step) instead of storing them in the database. If some devices truly
need unique credentials, either re-run with `--with-secrets` or set them per
node in the UI later.

## 3. Oxidized config

Replace the `source:` section and add the shared credentials:

```yaml
# shared credentials, resolved when a node has no override in the DB
username: backupuser
password: TheSharedPassword
vars:
  auth_methods: ["none", "publickey", "password", "keyboard-interactive"]
  enable: TheEnablePassword        # only if your devices need enable

# per-group credentials win over the globals above:
# groups:
#   dc-fabric:
#     username: otheruser
#     password: otherpass
#     vars:
#       enable: otherenable

source:
  default: sql
  sql:
    adapter: sqlite
    database: "/home/oxidized/nodedb/nodes.db"
    table: nodes
    map:
      name: name
      ip: ip
      model: model
      group: node_group
      username: username
      password: password
    vars_map:
      enable: enable
      ssh_port: ssh_port
```

Keep the existing `model_map:` section — it applies to the SQL source too.
Lock the config down (`chmod 600`, owner `oxidized`) since it now holds the
credentials, then restart oxidized and check the log / oxidized-web that all
nodes still load and back up. Once a full run is green, delete `router.db`.

Credential resolution order per node: DB column → group → global config.
NULL columns in the database fall through cleanly, so rows without
username/password use the shared credentials.

## 4. Web UI

Docker: already running if the container was started with `NODEDB_UI=true`
(see 1a) — nothing more to do.

Bare metal:

```sh
cp oxidized-nodedb-ui.service /etc/systemd/system/
# edit the unit: set NODEDB_UI_PASSWORD (or point EnvironmentFile at a
# root-readable env file) — without it the UI runs unauthenticated
systemctl daemon-reload
systemctl enable --now oxidized-nodedb-ui
```

Browse to `http://<host>:8889`. Adding/editing/deleting a node triggers
`GET /reload` on oxidized-web (`OXIDIZED_URL`, default
`http://127.0.0.1:8888`) so the change takes effect without waiting for the
next interval.

UI environment variables: `NODEDB_PATH`, `NODEDB_UI_PORT`, `NODEDB_UI_BIND`,
`NODEDB_UI_USER`/`NODEDB_UI_PASSWORD` (basic auth), `NODEDB_UI_PREFIX`
(subpath behind a reverse proxy), `OXIDIZED_URL` (empty string disables the
reload call).

## Behind oauth2-proxy (or any authenticating reverse proxy)

When the UI is only reachable through an authenticating proxy, skip
`NODEDB_UI_PASSWORD` entirely — basic auth exists for standalone setups.
Make sure the port is not reachable around the proxy: publish it as
`-p 127.0.0.1:8889:8889` (proxy on the same host) or not at all (proxy as a
container on the same Docker network, upstream `http://oxidized:8889`).

Two routing options:

- **Separate hostname** (`nodedb.example.com`): add a second
  vhost/upstream with the same oauth2 protection, pointing at port 8889.
  No UI configuration needed.
- **Subpath of the existing host** (`oxidized.example.com/nodedb/`): set
  `NODEDB_UI_PREFIX=/nodedb` on the container and route the path to port
  8889 *without* stripping the prefix — the app strips it itself and
  generates all links under it.
