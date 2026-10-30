-- Additive, repeatable migration. Run inside a transaction; never reset volumes.
SELECT pg_advisory_xact_lock(719731201);
ALTER TABLE information_artifact ADD COLUMN IF NOT EXISTS source_filename VARCHAR(255);
ALTER TABLE information_artifact ADD COLUMN IF NOT EXISTS source_mime_type VARCHAR(150);
ALTER TABLE information_artifact ADD COLUMN IF NOT EXISTS source_sha256 VARCHAR(64);
ALTER TABLE information_artifact ADD COLUMN IF NOT EXISTS source_family_id UUID;
ALTER TABLE information_artifact ADD COLUMN IF NOT EXISTS source_revision INTEGER CHECK (source_revision > 0);
ALTER TABLE information_artifact ADD COLUMN IF NOT EXISTS processing_status TEXT CHECK (processing_status IN ('processing','ready','failed'));
ALTER TABLE information_artifact ADD COLUMN IF NOT EXISTS processing_error TEXT;
ALTER TABLE information_artifact ADD COLUMN IF NOT EXISTS extraction_method TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS artifact_source_revision ON information_artifact(game_id,source_family_id,source_revision);
CREATE INDEX IF NOT EXISTS artifact_source_hash ON information_artifact(game_id,source_sha256);
CREATE TABLE IF NOT EXISTS document_source (
 artifact_id UUID PRIMARY KEY REFERENCES information_artifact(artifact_id),
 original_bytes BYTEA NOT NULL CHECK (octet_length(original_bytes) BETWEEN 1 AND 20971520)
);
ALTER TABLE artifact_chunk ADD COLUMN IF NOT EXISTS source_locator JSONB;
CREATE INDEX IF NOT EXISTS artifact_chunk_search ON artifact_chunk USING gin(to_tsvector('english',coalesce(text_excerpt,'')));
CREATE TABLE IF NOT EXISTS submission_citation (
 citation_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 package_id UUID NOT NULL REFERENCES turn_submission_package(package_id),
 move_id UUID REFERENCES move(move_id),
 chunk_id UUID NOT NULL REFERENCES artifact_chunk(chunk_id),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS citation_package_chunk ON submission_citation(package_id,chunk_id) WHERE move_id IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS citation_move_chunk ON submission_citation(move_id,chunk_id) WHERE move_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS citation_chunk ON submission_citation(chunk_id);
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='move'::regclass AND conname='move_package_identity') THEN
   ALTER TABLE move ADD CONSTRAINT move_package_identity UNIQUE(move_id,package_id);
 END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='submission_citation'::regclass AND conname='citation_move_package') THEN
   ALTER TABLE submission_citation ADD CONSTRAINT citation_move_package FOREIGN KEY(move_id,package_id) REFERENCES move(move_id,package_id);
 END IF;
END $$;
CREATE OR REPLACE FUNCTION wargame_cited_context_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_TABLE_NAME='turn' THEN
   IF NEW.game_id IS DISTINCT FROM OLD.game_id AND EXISTS(SELECT 1 FROM submission_citation c JOIN turn_submission_package p USING(package_id) WHERE p.turn_id=OLD.turn_id) THEN
     RAISE EXCEPTION 'Cited turn cannot be moved to another game';
   END IF;
 ELSE
   IF NEW.turn_id IS DISTINCT FROM OLD.turn_id AND EXISTS(
     SELECT 1 FROM submission_citation c JOIN artifact_chunk ch USING(chunk_id) JOIN information_artifact a USING(artifact_id)
     WHERE c.package_id=OLD.package_id AND a.game_id IS DISTINCT FROM (SELECT game_id FROM turn WHERE turn_id=NEW.turn_id)
   ) THEN RAISE EXCEPTION 'Cited package cannot be moved to another game'; END IF;
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS cited_context_guard ON turn;
CREATE TRIGGER cited_context_guard BEFORE UPDATE ON turn FOR EACH ROW EXECUTE FUNCTION wargame_cited_context_guard();
DROP TRIGGER IF EXISTS cited_context_guard ON turn_submission_package;
CREATE TRIGGER cited_context_guard BEFORE UPDATE ON turn_submission_package FOR EACH ROW EXECUTE FUNCTION wargame_cited_context_guard();
CREATE OR REPLACE FUNCTION wargame_citation_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE gid uuid; source_gid uuid; source_status text;
BEGIN
 SELECT t.game_id INTO gid FROM turn_submission_package p JOIN turn t USING(turn_id) WHERE p.package_id=NEW.package_id;
 IF NEW.move_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM move WHERE move_id=NEW.move_id AND package_id=NEW.package_id) THEN
   RAISE EXCEPTION 'Citation move must belong to its package';
 END IF;
 SELECT a.game_id,a.processing_status INTO source_gid,source_status FROM artifact_chunk c JOIN information_artifact a USING(artifact_id) JOIN document_source s USING(artifact_id) WHERE c.chunk_id=NEW.chunk_id FOR SHARE OF a,c;
 IF gid IS DISTINCT FROM source_gid OR source_status IS DISTINCT FROM 'ready' THEN
   RAISE EXCEPTION 'Citation needs a ready passage from the same game';
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS citation_guard ON submission_citation;
CREATE TRIGGER citation_guard BEFORE INSERT OR UPDATE ON submission_citation FOR EACH ROW EXECUTE FUNCTION wargame_citation_guard();
DROP TRIGGER IF EXISTS package_child_guard ON submission_citation;
CREATE TRIGGER package_child_guard BEFORE INSERT OR UPDATE OR DELETE ON submission_citation FOR EACH ROW EXECUTE FUNCTION wargame_package_child_guard();
CREATE OR REPLACE FUNCTION wargame_source_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_TABLE_NAME='document_source' THEN
   RAISE EXCEPTION 'Original source bytes are immutable; upload a new revision';
 ELSIF TG_TABLE_NAME='information_artifact' THEN
   IF EXISTS(SELECT 1 FROM document_source WHERE artifact_id=OLD.artifact_id) THEN
     IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Uploaded source is immutable'; END IF;
     IF OLD.processing_status='ready' OR
       (to_jsonb(NEW)-ARRAY['processing_status','processing_error','extraction_method']) IS DISTINCT FROM
       (to_jsonb(OLD)-ARRAY['processing_status','processing_error','extraction_method']) THEN
       RAISE EXCEPTION 'Uploaded source is immutable; upload a new revision';
     END IF;
   END IF;
 ELSE
   IF TG_OP<>'INSERT' AND EXISTS(SELECT 1 FROM document_source WHERE artifact_id=OLD.artifact_id) THEN
     RAISE EXCEPTION 'Extracted passages are immutable; upload a new revision';
   END IF;
   IF TG_OP<>'DELETE' AND EXISTS(SELECT 1 FROM document_source WHERE artifact_id=NEW.artifact_id) THEN
     PERFORM 1 FROM information_artifact WHERE artifact_id=NEW.artifact_id AND processing_status='processing' FOR UPDATE;
     IF NOT FOUND THEN RAISE EXCEPTION 'Passages can only be added during extraction'; END IF;
   END IF;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS source_guard ON information_artifact;
CREATE TRIGGER source_guard BEFORE UPDATE OR DELETE ON information_artifact FOR EACH ROW EXECUTE FUNCTION wargame_source_guard();
DROP TRIGGER IF EXISTS source_guard ON artifact_chunk;
CREATE TRIGGER source_guard BEFORE INSERT OR UPDATE OR DELETE ON artifact_chunk FOR EACH ROW EXECUTE FUNCTION wargame_source_guard();
DROP TRIGGER IF EXISTS source_guard ON document_source;
CREATE TRIGGER source_guard BEFORE UPDATE OR DELETE ON document_source FOR EACH ROW EXECUTE FUNCTION wargame_source_guard();
