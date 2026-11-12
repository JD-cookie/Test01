import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

export type Db = DatabaseSync;

// Schema migrations, applied in order. Never edit a shipped entry; append a new one.
const MIGRATIONS: string[] = [
  `
  CREATE TABLE users (
    id            TEXT PRIMARY KEY,           -- UUID v4
    email         TEXT NOT NULL UNIQUE,       -- normalized: trimmed + lowercased
    display_name  TEXT NOT NULL,
    password_hash TEXT NOT NULL,              -- scrypt$N$r$p$salt$hash
    created_at    TEXT NOT NULL               -- ISO 8601 UTC
  );
  CREATE TABLE sessions (
    token_hash  TEXT PRIMARY KEY,             -- SHA-256 hex of the bearer token
    user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at  TEXT NOT NULL,
    expires_at  TEXT NOT NULL
  );
  CREATE INDEX sessions_user_id ON sessions(user_id);
  `,
];

export function openDb(path: string): Db {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
  const db = new DatabaseSync(path);
  db.exec('PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;');
  const row = db.prepare('PRAGMA user_version').get() as { user_version: number };
  for (let v = row.user_version; v < MIGRATIONS.length; v++) {
    db.exec('BEGIN');
    try {
      db.exec(MIGRATIONS[v]);
      db.exec(`PRAGMA user_version = ${v + 1}`);
      db.exec('COMMIT');
    } catch (err) {
      db.exec('ROLLBACK');
      throw err;
    }
  }
  return db;
}
