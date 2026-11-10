-- The mechanical consolidation tier: decay stale observations, expire past-TTL memories.
-- It fires hourly, and sp_consolidate_mechanical (home/consolidator/tier1_mechanical.sql) throttles
-- itself to one real run per day, so a laptop that sleeps through midnight still gets its pass.
-- Needs event_scheduler = ON (db/server-settings.sql). No Claude involved: pure SQL.

DROP EVENT IF EXISTS ev_consolidate_mechanical;

CREATE EVENT ev_consolidate_mechanical
  ON SCHEDULE EVERY 1 HOUR STARTS CURRENT_TIMESTAMP + INTERVAL 5 MINUTE
  ON COMPLETION NOT PRESERVE ENABLE
  COMMENT 'Mechanical consolidation; hourly trigger, throttle does real work once/day (laptop-sleep tolerant)'
  DO CALL sp_consolidate_mechanical(CONCAT('event-', DATE_FORMAT(NOW(), '%Y%m%d')));
