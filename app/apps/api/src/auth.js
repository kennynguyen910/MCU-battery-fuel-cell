import { randomBytes, scryptSync, timingSafeEqual, createHash } from 'node:crypto';

const TTL_MS = 8 * 60 * 60 * 1000;

export class SingleUserAuth {
  constructor(username, password) {
    if (!username || !password || password.length < 12) {
      throw new Error('APP_USERNAME and APP_PASSWORD (at least 12 characters) are required together');
    }
    this.username = username;
    this.salt = randomBytes(16);
    this.passwordHash = scryptSync(password, this.salt, 32);
    this.tokens = new Map();
    this.attempts = new Map();
  }

  login(username, password, ip) {
    return this.verify(username, password, ip, { username: this.username,
      salt: this.salt, passwordHash: this.passwordHash });
  }

  verify(username, password, ip, user) {
    const now = Date.now();
    const recent = (this.attempts.get(ip) || []).filter(time => now - time < 15 * 60 * 1000);
    if (recent.length >= 10) return { error: 'Too many login attempts', status: 429 };
    // Hash every candidate, including an unknown username, to keep timing similar.
    const candidate = scryptSync(String(password), user?.salt ?? this.salt, 32);
    const valid = timingSafeEqual(candidate, user?.passwordHash ?? this.passwordHash) && username === user?.username;
    if (!valid) {
      recent.push(now);
      this.attempts.set(ip, recent);
      return { error: 'Invalid username or password', status: 401 };
    }
    this.attempts.delete(ip);
    const token = randomBytes(32).toString('base64url');
    this.tokens.set(this.digest(token), now + TTL_MS);
    return { token, expiresAt: new Date(now + TTL_MS).toISOString(), username };
  }

  digest(token) { return createHash('sha256').update(token).digest('hex'); }
  valid(token) {
    if (!token) return false;
    const key = this.digest(token);
    const expiry = this.tokens.get(key);
    if (!expiry || expiry <= Date.now()) {
      this.tokens.delete(key);
      return false;
    }
    return true;
  }
  logout(token) { if (token) this.tokens.delete(this.digest(token)); }
}
