-- duckdb "unread for a recipient" anti-join, file-direct (no daemon).
-- Read as DATA by the jsonl driver (scripts/drivers/storage/jsonl.sh) and never
-- parsed by bash, so its apostrophes and "double-quoted" identifiers can't trip
-- the macOS system bash 3.2 parser. The driver fills the placeholders by literal
-- bash substitution: __LG__ = events.jsonl path, __TL__ = team, __AL__ = agent
-- (all already SQL-escaped — apostrophes doubled — before substitution).
-- Columns are read as explicit VARCHAR, never read_json_auto, whose type
-- inference would parse `at` as a TIMESTAMP and drop the canonical ISO-8601 T/Z.
WITH log AS (
  SELECT * FROM read_json('__LG__', columns={type:'VARCHAR', id:'VARCHAR',
        team:'VARCHAR', "from":'VARCHAR', "to":'VARCHAR', body:'VARCHAR',
        at:'VARCHAR', msg_id:'VARCHAR', agent:'VARCHAR'}, format='newline_delimited')
), sent AS (
  SELECT *, row_number() OVER () AS position FROM log WHERE type='message_sent'
)
SELECT to_json(struct_pack(type := 'message_sent', id := s.id, team := s.team,
         "from" := s."from", "to" := s."to", body := s.body, at := s.at))
FROM sent s
WHERE s.position > __CUR__ AND s.team='__TL__' AND s."to"='__AL__'
AND s.id NOT IN (
  SELECT msg_id FROM log
  WHERE type='message_read' AND team='__TL__' AND agent='__AL__')
ORDER BY s.position;
