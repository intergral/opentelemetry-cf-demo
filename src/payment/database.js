const mysql = require('mysql2/promise');
const logger = require('pino')();

// Create connection pool
const pool = mysql.createPool({
  host: process.env.MYSQL_HOST || 'mysql',
  port: parseInt(process.env.MYSQL_PORT || '3306'),
  user: process.env.MYSQL_USER || 'quotes_user',
  password: process.env.MYSQL_PASSWORD || 'quotes_password',
  database: process.env.MYSQL_DATABASE || 'quotes',
  waitForConnections: true,
  connectionLimit: 10,
  queueLimit: 0,
  enableKeepAlive: true,
  keepAliveInitialDelay: 0
});

// Test connection on startup
pool.getConnection()
  .then(connection => {
    logger.info('MySQL connection pool established successfully');
    connection.release();
  })
  .catch(err => {
    logger.error({ err }, 'Failed to establish MySQL connection pool');
  });

// ---------------------------------------------------------------------------
// Optional per-query timeout, for the flagd-free database failure scenario.
//
// PAYMENT_QUERY_TIMEOUT_MS defaults to 0 (off), in which case this is exactly
// the previous behaviour: pool.execute() with no timeout.
//
// When set, the query is given a deadline. Paired with a jittery latency toxic
// on the payment -> MySQL link, a controllable share of queries exceed it and
// fail. Unlike a flag that throws before the database call, the failure happens
// INSIDE the database client, so the mysql2 instrumentation produces a DB
// client span that ends in error - real database-side evidence.
//
// Why this is not simply pool.execute({ sql, timeout }):
// mysql2 raises PROTOCOL_SEQUENCE_TIMEOUT WITHOUT setting err.fatal, so the
// pool keeps the connection even though its protocol is now desynchronised -
// the server's reply arrives after the client has given up, and the next query
// on that connection can receive the wrong response. So the connection has to
// be destroyed by hand. Verified against mysql2 3.11.5:
//   lib/commands/query.js   _handleTimeoutError() sets code/errorno only
//   lib/base/connection.js  err.fatal is set elsewhere, not here
// ---------------------------------------------------------------------------
const QUERY_TIMEOUT_MS = parseInt(process.env.PAYMENT_QUERY_TIMEOUT_MS || '0', 10);

async function executeWithTimeout(sql, values) {
  if (QUERY_TIMEOUT_MS <= 0) {
    return pool.execute(sql, values);
  }

  const conn = await pool.getConnection();
  let destroyed = false;
  try {
    return await conn.execute({ sql, timeout: QUERY_TIMEOUT_MS }, values);
  } catch (err) {
    if (err && err.code === 'PROTOCOL_SEQUENCE_TIMEOUT') {
      logger.warn({ err, timeoutMs: QUERY_TIMEOUT_MS },
        'Database query exceeded its deadline; destroying the connection');
      conn.destroy();
      destroyed = true;
    }
    throw err;
  } finally {
    if (!destroyed) {
      conn.release();
    }
  }
}

module.exports = pool;
module.exports.executeWithTimeout = executeWithTimeout;
module.exports.QUERY_TIMEOUT_MS = QUERY_TIMEOUT_MS;
