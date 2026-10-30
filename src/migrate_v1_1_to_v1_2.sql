-- GIWG v1.2. Apply once to a normalized v1.1 schema in a maintenance window.
-- Transaction aborts on incompatible existing data; it never silently repairs history.
BEGIN;
DROP TRIGGER enforce_world_state_immutability ON world_state;
DROP TRIGGER enforce_package_immutability ON turn_submission_package;
DROP TRIGGER protect_locked_package_moves ON move;
DROP TRIGGER protect_locked_package_actions ON action;
DROP TRIGGER enforce_adjudication_case_immutability ON adjudication_case;
DROP TRIGGER protect_resolved_case_outcomes ON outcome;
DROP TRIGGER protect_resolved_case_effects ON effect;
DROP FUNCTION trg_enforce_world_state_immutability();
DROP FUNCTION trg_enforce_package_immutability_and_transitions();
DROP FUNCTION trg_protect_locked_package_children();
DROP FUNCTION trg_enforce_adjudication_case_immutability();
DROP FUNCTION trg_protect_resolved_case_outcomes();

CREATE TABLE move_rfi (
 move_id uuid NOT NULL REFERENCES move(move_id),
 rfi_id uuid NOT NULL REFERENCES rfi(rfi_id),
 PRIMARY KEY(move_id,rfi_id)
);
INSERT INTO move_rfi SELECT related_move_id,rfi_id FROM rfi WHERE related_move_id IS NOT NULL;
DROP VIEW v_open_rfis;
ALTER TABLE rfi DROP COLUMN related_move_id;
CREATE VIEW v_open_rfis AS SELECT r.*,t.name AS team_name,p.display_name AS owner_name
 FROM rfi r JOIN player_team t ON t.team_id=r.requesting_team_id
 LEFT JOIN participant p ON p.participant_id=r.owner_participant_id
 WHERE r.status IN ('open','assigned','escalated');
CREATE TABLE outcome_desired_effect (
 outcome_id uuid NOT NULL REFERENCES outcome(outcome_id),
 desired_effect_id uuid NOT NULL REFERENCES desired_effect(desired_effect_id),
 PRIMARY KEY(outcome_id,desired_effect_id)
);
ALTER TABLE effect ALTER COLUMN outcome_id SET NOT NULL;
ALTER TABLE effect ALTER COLUMN effect_type SET NOT NULL;
ALTER TABLE outcome ALTER COLUMN success_level SET NOT NULL;
ALTER TABLE turn_submission_package ADD CHECK(revision >= 1);
ALTER TABLE move ADD CHECK(version >= 1);
ALTER TABLE dependency ADD CHECK(status IN ('pending','satisfied','blocked','waived'));
ALTER TABLE dependency ADD CHECK(type ~ '[^[:space:]]' AND type IS NOT NULL AND owner ~ '[^[:space:]]' AND owner IS NOT NULL);
ALTER TABLE action ADD CHECK(statement ~ '[^[:space:]]');
ALTER TABLE action ADD CHECK(action_class NOT IN ('MilitaryAction','CombatAction') OR
 (mission IS NOT NULL AND mission ~ '[^[:space:]]' AND forces IS NOT NULL AND forces ~ '[^[:space:]]'));
ALTER TABLE action ADD CHECK(action_class <> 'CombatAction' OR (method IS NOT NULL AND method ~ '[^[:space:]]'));
ALTER TABLE risk ADD CHECK(statement ~ '[^[:space:]]');
ALTER TABLE desired_effect ADD CHECK(effect ~ '[^[:space:]]');
ALTER TABLE rfi ADD CHECK(question ~ '[^[:space:]]');
ALTER TABLE rfi ADD CHECK(status <> 'assigned' OR owner_participant_id IS NOT NULL);
ALTER TABLE rfi ADD CHECK(status <> 'closed' OR closed_at IS NOT NULL);
ALTER TABLE rfi_response ADD CHECK(content ~ '[^[:space:]]');
ALTER TABLE outcome ADD CHECK(result ~ '[^[:space:]]');
ALTER TABLE effect ADD CHECK(effect_type ~ '[^[:space:]]');
ALTER TABLE world_state ADD CHECK(NOT is_published OR published_at IS NOT NULL);
ALTER TABLE turn_submission_package ADD CHECK(receipt_status NOT IN ('submitted','locked','accepted') OR submitted_at IS NOT NULL);
ALTER TABLE turn_submission_package ADD CHECK(receipt_status NOT IN ('locked','accepted') OR locked_at IS NOT NULL);
ALTER TABLE adjudication_case ADD CHECK(status <> 'resolved' OR
 (resolved_at IS NOT NULL AND rationale IS NOT NULL AND rationale ~ '[^[:space:]]'));

-- Central transition policy, also mirrored in workflow_rules.json.
CREATE TABLE workflow_transition (
 entity text NOT NULL, from_status text NOT NULL, to_status text NOT NULL,
 PRIMARY KEY(entity,from_status,to_status)
);
INSERT INTO workflow_transition VALUES
 ('turn','planned','open'),('turn','open','locked'),('turn','locked','adjudicated'),('turn','adjudicated','closed'),
 ('turn_submission_package','draft','submitted'),('turn_submission_package','submitted','locked'),
 ('turn_submission_package','submitted','returned'),('turn_submission_package','returned','submitted'),('turn_submission_package','locked','accepted'),
 ('move','draft','submitted'),('move','submitted','under_adjudication'),('move','under_adjudication','resolved'),('move','submitted','draft'),
 ('adjudication_case','open','in_progress'),('adjudication_case','in_progress','resolved'),
 ('adjudication_case','resolved','reopened'),('adjudication_case','reopened','in_progress'),('adjudication_case','reopened','resolved'),
 ('rfi','open','assigned'),('rfi','open','escalated'),('rfi','assigned','escalated'),('rfi','escalated','assigned'),
 ('rfi','assigned','answered'),('rfi','escalated','answered'),('rfi','answered','closed');
REVOKE ALL ON workflow_transition FROM PUBLIC;
GRANT SELECT ON workflow_transition TO PUBLIC;

CREATE FUNCTION giwg_workflow_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE o jsonb; n jsonb; field text; os text; ns text; initial text; ps text; gid uuid;
BEGIN
 n := to_jsonb(NEW);
 field := CASE WHEN TG_TABLE_NAME='turn_submission_package' THEN 'receipt_status' ELSE 'status' END;
 initial := CASE TG_TABLE_NAME WHEN 'turn' THEN 'planned' WHEN 'turn_submission_package' THEN 'draft' WHEN 'move' THEN 'draft' ELSE 'open' END;
 ns := n->>field;
 IF TG_OP='INSERT' THEN
   IF ns <> initial THEN RAISE EXCEPTION 'Initial % status must be %, got %',TG_TABLE_NAME,initial,ns; END IF;
   IF TG_TABLE_NAME='move' THEN
     SELECT receipt_status::text INTO ps FROM turn_submission_package WHERE package_id=NEW.package_id FOR UPDATE;
     IF ps IN ('submitted','locked','accepted') THEN RAISE EXCEPTION 'Cannot add draft move to submitted package'; END IF;
   END IF;
   RETURN NEW;
 END IF;
 o := to_jsonb(OLD); os := o->>field;
 IF os <> ns AND NOT EXISTS(SELECT 1 FROM workflow_transition WHERE entity=TG_TABLE_NAME AND from_status=os AND to_status=ns) THEN
   RAISE EXCEPTION 'Invalid % transition: % -> %',TG_TABLE_NAME,os,ns;
 END IF;
 IF TG_TABLE_NAME='move' THEN
   SELECT receipt_status::text INTO ps FROM turn_submission_package WHERE package_id=NEW.package_id FOR UPDATE;
   IF ns='draft' AND os='submitted' AND ps IS DISTINCT FROM 'returned' THEN
     RAISE EXCEPTION 'Move reset requires returned package';
   END IF;
   IF (ps IN ('submitted','locked','accepted') AND ns='draft') OR (ps IN ('draft','returned') AND ns IN ('under_adjudication','resolved')) THEN
     RAISE EXCEPTION 'Move status incompatible with package';
   END IF;
 ELSIF TG_TABLE_NAME='turn_submission_package' THEN
   IF os IN ('locked','accepted') AND (n-'receipt_status') IS DISTINCT FROM (o-'receipt_status') THEN
     RAISE EXCEPTION 'Locked package content is immutable';
   END IF;
   IF os='returned' AND ns='submitted' AND NEW.revision <= OLD.revision THEN
     RAISE EXCEPTION 'Resubmission must increment revision';
   END IF;
   IF ns='submitted' AND os<>ns THEN NEW.submitted_at:=clock_timestamp(); END IF;
   IF ns='locked' AND os<>ns THEN NEW.locked_at:=clock_timestamp(); END IF;
   IF ns IN ('submitted','locked','accepted') AND EXISTS(SELECT 1 FROM move WHERE package_id=NEW.package_id AND status='draft') THEN
     RAISE EXCEPTION 'Submit moves before submitting/locking package';
   END IF;
 ELSIF TG_TABLE_NAME='adjudication_case' THEN
   IF os='resolved' THEN
     IF ns<>'reopened' OR (n-'status') IS DISTINCT FROM (o-'status') THEN
       RAISE EXCEPTION 'Resolved case requires a status-only reopen';
     END IF;
     SELECT t.game_id INTO gid FROM move m JOIN turn t USING(turn_id)
       WHERE m.move_id=COALESCE(NEW.move_id,(SELECT move_id FROM action WHERE action_id=NEW.action_id));
     INSERT INTO game_event(game_id,event_type,related_case_id,recorded_by,payload)
       VALUES(gid,'case_reopened',NEW.case_id,NEW.adjudicator_id,jsonb_build_object('database_user',current_user,'previous_resolved_at',OLD.resolved_at));
   END IF;
   IF ns='resolved' AND os<>ns THEN
     NEW.resolved_at:=clock_timestamp();
     IF NOT EXISTS(SELECT 1 FROM outcome WHERE case_id=NEW.case_id) THEN RAISE EXCEPTION 'Resolved case needs an outcome'; END IF;
   END IF;
 ELSIF TG_TABLE_NAME='rfi' THEN
   IF ns='closed' AND os<>ns THEN NEW.closed_at:=clock_timestamp(); END IF;
   IF ns IN ('answered','closed') AND NOT EXISTS(SELECT 1 FROM rfi_response WHERE rfi_id=NEW.rfi_id) THEN
     RAISE EXCEPTION 'Answered RFI needs a response';
   END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER workflow_guard BEFORE INSERT OR UPDATE ON turn FOR EACH ROW EXECUTE FUNCTION giwg_workflow_guard();
CREATE TRIGGER workflow_guard BEFORE INSERT OR UPDATE ON turn_submission_package FOR EACH ROW EXECUTE FUNCTION giwg_workflow_guard();
CREATE TRIGGER workflow_guard BEFORE INSERT OR UPDATE ON move FOR EACH ROW EXECUTE FUNCTION giwg_workflow_guard();
CREATE TRIGGER workflow_guard BEFORE INSERT OR UPDATE ON adjudication_case FOR EACH ROW EXECUTE FUNCTION giwg_workflow_guard();
CREATE TRIGGER workflow_guard BEFORE INSERT OR UPDATE ON rfi FOR EACH ROW EXECUTE FUNCTION giwg_workflow_guard();

CREATE FUNCTION giwg_immutable_header() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE o jsonb; n jsonb;
BEGIN
 IF TG_OP <> 'INSERT' THEN o:=to_jsonb(OLD); END IF;
 IF TG_TABLE_NAME='world_state' THEN
   IF COALESCE((o->>'is_published')::boolean,false) THEN RAISE EXCEPTION 'Published world state is immutable'; END IF;
   IF TG_OP<>'DELETE' THEN
     IF NEW.is_published THEN NEW.published_at:=COALESCE(NEW.published_at,clock_timestamp()); END IF;
   END IF;
 ELSIF TG_OP='DELETE' AND ((TG_TABLE_NAME='turn_submission_package' AND o->>'receipt_status' IN ('locked','accepted')) OR
      (TG_TABLE_NAME='adjudication_case' AND o->>'status'='resolved')) THEN
   RAISE EXCEPTION 'Locked/resolved header is immutable';
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER immutable_header BEFORE INSERT OR UPDATE OR DELETE ON world_state FOR EACH ROW EXECUTE FUNCTION giwg_immutable_header();
CREATE TRIGGER immutable_header BEFORE DELETE ON turn_submission_package FOR EACH ROW EXECUTE FUNCTION giwg_immutable_header();
CREATE TRIGGER immutable_header BEFORE DELETE ON adjudication_case FOR EACH ROW EXECUTE FUNCTION giwg_immutable_header();

-- Resolve all ancestry paths from JSONB rather than referencing nonexistent NEW fields.
-- Parent locks serialize content changes against concurrent header locking/resolution.
CREATE FUNCTION giwg_packages_for_row(tbl text, r jsonb) RETURNS SETOF uuid LANGUAGE plpgsql AS $$
DECLARE mid uuid; aid uuid; pid uuid;
BEGIN
 IF r IS NULL THEN RETURN; END IF;
 IF r->>'package_id' IS NOT NULL THEN RETURN NEXT (r->>'package_id')::uuid; END IF;
 IF r->>'move_id' IS NOT NULL THEN
   mid:=(r->>'move_id')::uuid;
   SELECT package_id INTO pid FROM move WHERE move_id=mid FOR UPDATE;
   IF pid IS NOT NULL THEN RETURN NEXT pid; END IF;
 END IF;
 IF r->>'action_id' IS NOT NULL THEN
   aid:=(r->>'action_id')::uuid;
   SELECT move_id INTO mid FROM action WHERE action_id=aid FOR UPDATE;
   SELECT package_id INTO pid FROM move WHERE move_id=mid FOR UPDATE;
   IF pid IS NOT NULL THEN RETURN NEXT pid; END IF;
 END IF;
END $$;
CREATE FUNCTION giwg_package_child_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE o jsonb; n jsonb; pid uuid; st text;
BEGIN
 IF TG_OP<>'INSERT' THEN o:=to_jsonb(OLD); END IF;
 IF TG_OP<>'DELETE' THEN n:=to_jsonb(NEW); END IF;
 FOR pid IN SELECT DISTINCT x FROM (
   SELECT giwg_packages_for_row(TG_TABLE_NAME,o) x UNION ALL SELECT giwg_packages_for_row(TG_TABLE_NAME,n) x
 ) q WHERE x IS NOT NULL ORDER BY x LOOP
   SELECT receipt_status::text INTO st FROM turn_submission_package WHERE package_id=pid FOR UPDATE;
   IF st IN ('locked','accepted') THEN
     IF TG_TABLE_NAME='move' AND TG_OP='UPDATE' THEN
       IF (n-'status') IS NOT DISTINCT FROM (o-'status') THEN CONTINUE; END IF;
     END IF;
     RAISE EXCEPTION 'Locked package % protects % content',pid,TG_TABLE_NAME;
   END IF;
 END LOOP;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['move','action','instrument_of_power','dependency','risk','desired_effect','package_artifact','move_artifact','move_rfi'] LOOP
   EXECUTE format('CREATE TRIGGER package_child_guard BEFORE INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION giwg_package_child_guard()',t);
 END LOOP;
END $$;

CREATE FUNCTION giwg_cases_for_row(tbl text,r jsonb) RETURNS SETOF uuid LANGUAGE plpgsql AS $$
DECLARE cid uuid; oid uuid; rid uuid;
BEGIN
 IF r IS NULL THEN RETURN; END IF;
 IF r->>'case_id' IS NOT NULL THEN RETURN NEXT (r->>'case_id')::uuid; END IF;
 IF r->>'outcome_id' IS NOT NULL THEN
   oid:=(r->>'outcome_id')::uuid;
   SELECT case_id INTO cid FROM outcome WHERE outcome_id=oid FOR UPDATE;
   IF cid IS NOT NULL THEN RETURN NEXT cid; END IF;
 END IF;
 IF tbl='ms_run' AND r->>'crr_id' IS NOT NULL THEN
   rid:=(r->>'crr_id')::uuid;
   SELECT case_id INTO cid FROM combat_resolution_request WHERE crr_id=rid FOR UPDATE;
   IF cid IS NOT NULL THEN RETURN NEXT cid; END IF;
 END IF;
 IF tbl='transition_effect' AND r->>'effect_id' IS NOT NULL THEN
   SELECT outcome_id INTO oid FROM effect WHERE effect_id=(r->>'effect_id')::uuid FOR UPDATE;
   SELECT case_id INTO cid FROM outcome WHERE outcome_id=oid FOR UPDATE;
   IF cid IS NOT NULL THEN RETURN NEXT cid; END IF;
 END IF;
END $$;
CREATE FUNCTION giwg_case_child_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE o jsonb; n jsonb; cid uuid; st text;
BEGIN
 IF TG_OP<>'INSERT' THEN o:=to_jsonb(OLD); END IF;
 IF TG_OP<>'DELETE' THEN n:=to_jsonb(NEW); END IF;
 FOR cid IN SELECT DISTINCT x FROM (
   SELECT giwg_cases_for_row(TG_TABLE_NAME,o) x UNION ALL SELECT giwg_cases_for_row(TG_TABLE_NAME,n) x
 ) q WHERE x IS NOT NULL ORDER BY x LOOP
   SELECT status::text INTO st FROM adjudication_case WHERE case_id=cid FOR UPDATE;
   IF st='resolved' THEN RAISE EXCEPTION 'Resolved case % protects %',cid,TG_TABLE_NAME; END IF;
 END LOOP;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['outcome','effect','case_evidence','ms_run','combat_resolution_request','outcome_desired_effect'] LOOP
   EXECUTE format('CREATE TRIGGER case_child_guard BEFORE INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION giwg_case_child_guard()',t);
 END LOOP;
END $$;
-- transition_effect is a later authorization association: it may be added after resolution.
-- Changes to an outcome/effect itself remain blocked.

-- Validate move/package identity and dual-parent consistency.
CREATE FUNCTION giwg_consistency_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE r jsonb:=to_jsonb(NEW); p turn_submission_package%ROWTYPE; mid uuid; g1 uuid; g2 uuid;
BEGIN
 IF TG_TABLE_NAME='move' AND r->>'package_id' IS NOT NULL THEN
   SELECT * INTO p FROM turn_submission_package WHERE package_id=NEW.package_id;
   IF NEW.team_id<>p.submitting_team_id OR NEW.turn_id<>p.turn_id THEN RAISE EXCEPTION 'Move/package team or turn mismatch'; END IF;
 ELSIF TG_TABLE_NAME IN ('dependency','risk','adjudication_case') AND r->>'move_id' IS NOT NULL AND r->>'action_id' IS NOT NULL THEN
   SELECT move_id INTO mid FROM action WHERE action_id=(r->>'action_id')::uuid;
   IF mid<>(r->>'move_id')::uuid THEN RAISE EXCEPTION 'Action/move mismatch'; END IF;
 ELSIF TG_TABLE_NAME='turn_submission_package' THEN
   SELECT game_id INTO g1 FROM turn WHERE turn_id=NEW.turn_id;
   SELECT game_id INTO g2 FROM player_team WHERE team_id=NEW.submitting_team_id;
   IF g1<>g2 THEN RAISE EXCEPTION 'Package team/turn game mismatch'; END IF;
 ELSIF TG_TABLE_NAME='state_transition' THEN
   SELECT game_id INTO g1 FROM world_state WHERE world_state_id=NEW.from_state_id;
   SELECT game_id INTO g2 FROM world_state WHERE world_state_id=NEW.to_state_id;
   IF g1<>g2 OR NEW.from_state_id=NEW.to_state_id THEN RAISE EXCEPTION 'Invalid state transition endpoints'; END IF;
 END IF;
 RETURN NEW;
END $$;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['move','dependency','risk','adjudication_case','turn_submission_package','state_transition'] LOOP
   EXECUTE format('CREATE TRIGGER consistency_guard BEFORE INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION giwg_consistency_guard()',t);
 END LOOP;
END $$;

-- Preserve the answered/closed response invariant when response rows are reparented/deleted.
CREATE FUNCTION giwg_response_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE st text;
BEGIN
 IF TG_OP='DELETE' OR to_jsonb(NEW)->>'rfi_id' IS DISTINCT FROM to_jsonb(OLD)->>'rfi_id' THEN
   SELECT status::text INTO st FROM rfi WHERE rfi_id=OLD.rfi_id FOR UPDATE;
   IF st IN ('answered','closed') AND NOT EXISTS(
     SELECT 1 FROM rfi_response WHERE rfi_id=OLD.rfi_id AND response_id<>OLD.response_id
   ) THEN RAISE EXCEPTION 'Cannot remove last response from answered/closed RFI'; END IF;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER response_guard BEFORE UPDATE OR DELETE ON rfi_response FOR EACH ROW EXECUTE FUNCTION giwg_response_guard();

COMMIT;
