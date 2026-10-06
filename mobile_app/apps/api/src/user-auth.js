import { randomBytes, scryptSync } from 'node:crypto';
import { SingleUserAuth } from './auth.js';

export function validateCredentials(username, password) {
  if (typeof username !== 'string' || !/^[A-Za-z0-9_.-]{1,100}$/.test(username))
    throw new Error('Username must be 1–100 letters, numbers, dots, underscores, or hyphens.');
  if (typeof password !== 'string' || password.length < 12 || password.length > 1000)
    throw new Error('Password must be 12–1000 characters.');
}

export class DatabaseAuth extends SingleUserAuth {
  constructor(pool) {
    // Random fallback hash makes unknown-user password checks follow the same path.
    super('_fallback', randomBytes(32).toString('hex'));
    this.pool = pool;
  }

  async initialize(username, password) {
    await this.pool.query(`CREATE TABLE IF NOT EXISTS app_user (
      username TEXT PRIMARY KEY,
      password_salt BYTEA NOT NULL,
      password_hash BYTEA NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CHECK (username ~ '^[A-Za-z0-9_.-]{1,100}$'),
      CHECK (octet_length(password_salt) = 16),
      CHECK (octet_length(password_hash) = 32)
    )`);
    // Seed only: restarting never overwrites an existing account's password.
    if (username !== undefined || password !== undefined)
      await this.addUser(username, password, { ifMissing: true });
  }

  async addUser(username, password, { ifMissing = false } = {}) {
    validateCredentials(username, password);
    const salt = randomBytes(16);
    const hash = scryptSync(password, salt, 32);
    try {
      const result = await this.pool.query(`INSERT INTO app_user
        (username, password_salt, password_hash) VALUES ($1, $2, $3)
        ${ifMissing ? 'ON CONFLICT (username) DO NOTHING' : ''}`,
      [username, salt, hash]);
      return result.rowCount === 1;
    } catch (error) {
      if (error.code === '23505') throw new Error('That username already exists. No password was changed.');
      throw error;
    }
  }

  async login(username, password, ip) {
    const { rows } = await this.pool.query(`SELECT username,
      password_salt AS salt, password_hash AS "passwordHash"
      FROM app_user WHERE username = $1`, [username]);
    return this.verify(username, password, ip, rows[0]);
  }
}
