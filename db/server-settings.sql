-- Server settings the memory system relies on. SET PERSIST survives a restart (MySQL 8.0+) and
-- needs SYSTEM_VARIABLES_ADMIN, which root has. Skip with: install.ps1 -SkipServerSettings
--
-- event_scheduler     runs ev_consolidate_mechanical (db/event.sql), the hourly mechanical tier.
-- max_allowed_packet  every transcript reader does UNCOMPRESS(raw_jsonl), which returns NULL for a
--                     transcript larger than this. 1G is MySQL's ceiling; 200+ MB transcripts happen.
--
-- local_infile is deliberately NOT persisted: archive_transcripts.ps1 turns it on for its own run.

SET PERSIST event_scheduler = ON;
SET PERSIST max_allowed_packet = 1073741824;
