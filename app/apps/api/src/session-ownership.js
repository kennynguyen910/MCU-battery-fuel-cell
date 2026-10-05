// Additive upgrade: legacy rows keep NULL ownership and remain admin-visible.
// A short lock timeout fails startup cleanly instead of blocking a busy collector.
export async function migrateSessionOwnership(pool) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SET LOCAL lock_timeout = '2s'");
    await client.query('ALTER TABLE test_session ADD COLUMN IF NOT EXISTS owner_username TEXT');
    await client.query('COMMIT');
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
  // Concurrent creation leaves existing reads and writes available. Run outside
  // the transaction; session and measurement IDs/constraints stay unchanged.
  await pool.query(`CREATE INDEX CONCURRENTLY IF NOT EXISTS test_session_owner_start_time_idx
    ON test_session (owner_username, start_time DESC)`);
}
