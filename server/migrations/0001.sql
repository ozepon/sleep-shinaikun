CREATE TABLE devices (
 id TEXT PRIMARY KEY, mac_hash TEXT UNIQUE NOT NULL, phone_hash TEXT UNIQUE,
 pair_hash TEXT, pair_until INTEGER, subscription TEXT,
 active INTEGER NOT NULL DEFAULT 1 CHECK(active IN (0,1))
);
CREATE TABLE commands (
 id TEXT PRIMARY KEY, device TEXT NOT NULL REFERENCES devices(id),
 state TEXT NOT NULL CHECK(state IN ('pending','executing','off','failed','expired','unknown')),
 created INTEGER NOT NULL, expires INTEGER NOT NULL, completed INTEGER
);
CREATE UNIQUE INDEX one_command ON commands(device) WHERE state IN ('pending','executing');
CREATE TABLE deliveries (
 id TEXT PRIMARY KEY, device TEXT NOT NULL, day TEXT NOT NULL, kind TEXT NOT NULL,
 state TEXT NOT NULL DEFAULT 'sending', lease INTEGER NOT NULL
);
CREATE INDEX delivery_day ON deliveries(day,device);
