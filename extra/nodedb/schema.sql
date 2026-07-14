-- Node inventory for the Oxidized SQL source (sqlite adapter).
-- Secrets (username/password/enable) are intentionally nullable: leave them
-- NULL and Oxidized falls back to group/global credentials in its config.
CREATE TABLE IF NOT EXISTS nodes (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  name       TEXT NOT NULL UNIQUE,
  ip         TEXT,
  model      TEXT NOT NULL,
  node_group TEXT,             -- "group" is an SQL keyword, hence node_group
  username   TEXT,             -- per-device override only, prefer NULL
  password   TEXT,             -- per-device override only, prefer NULL
  enable     TEXT,             -- per-device override only, prefer NULL
  ssh_port   INTEGER,          -- NULL = 22
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_nodes_group ON nodes (node_group);
