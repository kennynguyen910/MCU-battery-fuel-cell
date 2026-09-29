-- Read-only evidence: identity, encryption, persisted counts and sessions.
SELECT current_database() AS database_name, current_user AS database_user,
       inet_server_addr() AS server_address, inet_server_port() AS server_port;
SELECT ssl, version, cipher FROM pg_stat_ssl WHERE pid = pg_backend_pid();
SELECT (SELECT COUNT(*) FROM monitor_device) AS devices,
       (SELECT COUNT(*) FROM test_session) AS sessions,
       (SELECT COUNT(*) FROM measurement) AS measurement_rows;
SELECT s.session_name, COUNT(DISTINCT m.recorded_at) AS samples,
       COUNT(m.measurement_id) AS measurement_rows,
       MAX(m.recorded_at) AS last_measurement
FROM test_session s LEFT JOIN measurement m USING (session_id)
GROUP BY s.session_id, s.session_name ORDER BY s.start_time DESC LIMIT 10;
