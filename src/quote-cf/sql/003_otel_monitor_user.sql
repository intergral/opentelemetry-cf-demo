-- Copyright The OpenTelemetry Authors
-- SPDX-License-Identifier: Apache-2.0
--
-- Read-only monitoring user for the OTel collector's mysql receiver, so
-- OpsPilot gets database-side metrics alongside payment's DB client spans.
--
-- The receiver needs PROCESS and REPLICATION CLIENT for global status and
-- InnoDB metrics, and SELECT on performance_schema for statement and I/O
-- metrics. It is granted nothing that can modify data.
--
-- The password is a local-only demo value and is overridden from .env.override
-- via MYSQL_MONITOR_PASSWORD, which the collector reads. Keep the two in step.

CREATE USER IF NOT EXISTS 'otel_monitor'@'%' IDENTIFIED BY 'otel_monitor_password';

GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'otel_monitor'@'%';
GRANT SELECT ON performance_schema.* TO 'otel_monitor'@'%';
-- Read-only access to the demo schema so per-table size and io_waits metrics
-- are populated. SELECT only: the user cannot modify anything.
GRANT SELECT ON quotes.* TO 'otel_monitor'@'%';

FLUSH PRIVILEGES;
