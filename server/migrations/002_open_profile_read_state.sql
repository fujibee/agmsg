-- Open profile: a late joiner's read state must be accepted even before the
-- roster has caught up to them. read_frontiers and read_exact carried a
-- foreign key to members, and syncReadState additionally rejected any update
-- naming a member_id absent from members ("inactive member"). Both enforced
-- the same requirement -- that the member row exist first -- and both are
-- removed together here: the server now trusts member_id as an opaque
-- identifier for read state, the same way it already treats wire_id.
--
-- Idempotent: the DO block finds no matching constraint on a second run.
DO $$
DECLARE
  con RECORD;
BEGIN
  FOR con IN
    SELECT conname FROM pg_constraint
     WHERE conrelid = 'read_frontiers'::regclass AND contype = 'f'
  LOOP
    EXECUTE format('ALTER TABLE read_frontiers DROP CONSTRAINT %I', con.conname);
  END LOOP;

  FOR con IN
    SELECT conname FROM pg_constraint
     WHERE conrelid = 'read_exact'::regclass AND contype = 'f'
  LOOP
    EXECUTE format('ALTER TABLE read_exact DROP CONSTRAINT %I', con.conname);
  END LOOP;
END $$;
