-- Copyright The OpenTelemetry Authors
-- SPDX-License-Identifier: Apache-2.0
--
-- Scheduled prune for the quotes table.
--
-- WHY THIS EXISTS
-- getquote.cfm inserts a row per quote and nothing removed them except
-- removeoldquotes.cfm, which was disabled in the load generator because its
-- query is pathological (triple CROSS JOIN, ~26 minutes, billions of rows
-- examined). With the brake removed the table grew ~875 rows/day, and because
-- quote_number was drawn at random from a small space with a UNIQUE
-- constraint, duplicate-key errors climbed from ~0% to 13.6% of quote calls
-- and broke ~9.5% of checkouts.
--
-- This replaces removeoldquotes.cfm's only useful function - deleting old
-- quotes - without its query. quote_items has ON DELETE CASCADE against
-- quotes, so items are removed automatically.
--
-- Retention is 30 days. At ~875 rows/day that caps the table near 26,000 rows.
-- Paired with the widened quote_number range in getquote.cfm (900,000 values)
-- that is roughly a 2.9% collision rate; shorten the interval if the demo ever
-- runs at materially higher volume.
--
-- Requires event_scheduler=ON, which is the default in this MySQL 8 image.

USE quotes;

CREATE EVENT IF NOT EXISTS prune_old_quotes
    ON SCHEDULE EVERY 1 DAY
    STARTS CURRENT_TIMESTAMP + INTERVAL 1 HOUR
    COMMENT 'Delete quotes older than 30 days; quote_items cascade'
    DO
        DELETE FROM quotes WHERE quote_date < CURDATE() - INTERVAL 30 DAY;
