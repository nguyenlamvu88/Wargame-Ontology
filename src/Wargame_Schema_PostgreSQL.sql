-- Wargame initial database installation. Run once against an empty database.
BEGIN;
-- =============================================================================

-- Wargame Physical Data Schema (PostgreSQL)

-- Derived from: Wargame ontology, turn process and requirements

-- Companion: WARGAME_Data_Dictionary_and_Schema.xlsx

-- Initial implementation | UNCLASSIFIED

-- =============================================================================

-- Design notes:

--   * UUIDs as primary keys (gen_random_uuid() requires pgcrypto)

--   * Append-only / immutability for published WorldState, locked submissions,

--     resolved adjudication outcomes enforced in application + optional triggers

--   * JSONB for flexible payloads (state variables, permissions, event payload)

--   * Inheritance for Action subtypes and InformationArtifact subtypes via

--     discriminator columns (action_class, artifact_type) — single-table style

--   * Temporal fields: game_time (in-game label), valid_time_*, wall-clock timestamps

-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- -----------------------------------------------------------------------------

-- ENUMERATIONS

-- -----------------------------------------------------------------------------

CREATE TYPE turn_status AS ENUM (

  'planned', 'open', 'locked', 'adjudicated', 'closed'

);

CREATE TYPE package_receipt_status AS ENUM (

  'draft', 'submitted', 'locked', 'accepted', 'returned'

);

CREATE TYPE rfi_status AS ENUM (

  'open', 'assigned', 'answered', 'closed', 'escalated'

);

CREATE TYPE rfi_priority AS ENUM (

  'low', 'medium', 'high', 'urgent'

);

CREATE TYPE adjudication_track AS ENUM (

  'kinetic', 'DIE', 'SAP', 'other'

);

CREATE TYPE adjudication_case_status AS ENUM (

  'open', 'in_progress', 'resolved', 'reopened'

);

CREATE TYPE success_level AS ENUM (

  'full', 'partial', 'failed', 'inconclusive'

);

CREATE TYPE role_type AS ENUM (

  'player', 'adjudicator', 'control', 'analyst', 'director'

);

CREATE TYPE interface_type AS ENUM (

  'planning_risk', 'coa_refinement', 'preadj_rb', 'rbo_adj', 'future_ops'

);

CREATE TYPE interface_direction AS ENUM (

  'into_main', 'from_main', 'bidirectional'

);

CREATE TYPE artifact_type AS ENUM (

  'report', 'assessment', 'observation', 'news', 'evidence',

  'ms_result', 'analysis_product', 'rfi_response', 'other'

);

CREATE TYPE action_class AS ENUM (

  'Action', 'MilitaryAction', 'CombatAction'

);

CREATE TYPE move_status AS ENUM (

  'draft', 'submitted', 'under_adjudication', 'resolved'

);

CREATE TYPE game_status AS ENUM (

  'planned', 'active', 'closed'

);

CREATE TYPE instrument_category AS ENUM (

  'diplomatic', 'information', 'military', 'economic', 'other'

);

-- -----------------------------------------------------------------------------

-- CORE: GAME CONTAINER

-- -----------------------------------------------------------------------------

CREATE TABLE wargame_game (

  game_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  name              VARCHAR(200) NOT NULL,

  objectives        TEXT,

  configuration     JSONB,

  access_model      VARCHAR(50),

  status            game_status NOT NULL DEFAULT 'planned',

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  created_by        UUID,

  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  classification_marking VARCHAR(50)

);

CREATE TABLE scenario (

  scenario_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  game_id             UUID NOT NULL REFERENCES wargame_game(game_id),

  scope               TEXT,

  initial_conditions  JSONB,

  assumptions         TEXT,

  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()

);

CREATE INDEX idx_scenario_game ON scenario(game_id);

CREATE TABLE rule_set (

  ruleset_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  game_id           UUID REFERENCES wargame_game(game_id),

  version           VARCHAR(30) NOT NULL,

  applicability     TEXT,

  approval_status   VARCHAR(30) NOT NULL DEFAULT 'draft',

  content_uri       VARCHAR(500),

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE (game_id, version)

);

-- -----------------------------------------------------------------------------

-- ACTORS & PARTICIPANTS

-- -----------------------------------------------------------------------------

CREATE TABLE participant (

  participant_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  organization      VARCHAR(200),

  display_name      VARCHAR(200),

  email             VARCHAR(200),

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()

);

CREATE TABLE role (

  role_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  role_type         role_type NOT NULL,

  scope             TEXT,

  permissions       JSONB,

  authority         TEXT

);

CREATE TABLE participant_role (

  participant_id    UUID NOT NULL REFERENCES participant(participant_id),

  role_id           UUID NOT NULL REFERENCES role(role_id),

  game_id           UUID REFERENCES wargame_game(game_id),

  assigned_at       TIMESTAMPTZ NOT NULL DEFAULT now(),

  PRIMARY KEY (participant_id, role_id, game_id)

);

CREATE TABLE player_team (

  team_id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  game_id               UUID NOT NULL REFERENCES wargame_game(game_id),

  name                  VARCHAR(100) NOT NULL,

  lead_participant_id   UUID REFERENCES participant(participant_id),

  workspace_ref         VARCHAR(200),

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now()

);

CREATE INDEX idx_player_team_game ON player_team(game_id);

CREATE TABLE team_member (

  team_id           UUID NOT NULL REFERENCES player_team(team_id),

  participant_id    UUID NOT NULL REFERENCES participant(participant_id),

  joined_at         TIMESTAMPTZ NOT NULL DEFAULT now(),

  PRIMARY KEY (team_id, participant_id)

);

CREATE TABLE actor (

  actor_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  game_id           UUID NOT NULL REFERENCES wargame_game(game_id),

  name              VARCHAR(200) NOT NULL,

  actor_type        VARCHAR(50),  -- state | organization | coalition | other

  objectives        TEXT,

  authorities       TEXT,

  is_coalition      BOOLEAN NOT NULL DEFAULT false,

  membership        JSONB,        -- for coalitions

  decision_mechanism TEXT,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()

);

CREATE TABLE team_actor (

  team_id           UUID NOT NULL REFERENCES player_team(team_id),

  actor_id          UUID NOT NULL REFERENCES actor(actor_id),

  relationship      VARCHAR(30) NOT NULL DEFAULT 'represents', -- represents | controls

  PRIMARY KEY (team_id, actor_id, relationship)

);

CREATE TABLE capability (

  capability_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  actor_id          UUID NOT NULL REFERENCES actor(actor_id),

  type              VARCHAR(100),

  availability      VARCHAR(100),

  constraints       TEXT

);

CREATE TABLE actor_relationship (

  relationship_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  game_id           UUID NOT NULL REFERENCES wargame_game(game_id),

  relationship_type VARCHAR(50) NOT NULL,

  actor_a_id        UUID NOT NULL REFERENCES actor(actor_id),

  actor_b_id        UUID NOT NULL REFERENCES actor(actor_id),

  valid_time_start  TIMESTAMPTZ,

  valid_time_end    TIMESTAMPTZ,

  confidence        VARCHAR(30)

);

-- -----------------------------------------------------------------------------

-- TURN LIFECYCLE

-- -----------------------------------------------------------------------------

CREATE TABLE turn (

  turn_id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  game_id                   UUID NOT NULL REFERENCES wargame_game(game_id),

  turn_number               INTEGER NOT NULL,

  game_time                 VARCHAR(100),

  status                    turn_status NOT NULL DEFAULT 'planned',

  resulting_state_id        UUID,  -- FK added after world_state exists

  opened_at                 TIMESTAMPTZ,

  submission_deadline       TIMESTAMPTZ,

  closed_at                 TIMESTAMPTZ,

  created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE (game_id, turn_number)

);

CREATE INDEX idx_turn_game ON turn(game_id);

CREATE TABLE turn_stage (

  stage_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  turn_id           UUID NOT NULL REFERENCES turn(turn_id),

  stage_type        VARCHAR(50) NOT NULL,  -- GSU|START|PCTD|SUBMIT|ADJ|STATE|GSD

  ordinal           INTEGER NOT NULL,

  entry_criteria    TEXT,

  exit_criteria     TEXT,

  status            VARCHAR(30) DEFAULT 'pending',

  entered_at        TIMESTAMPTZ,

  exited_at         TIMESTAMPTZ,

  UNIQUE (turn_id, stage_type)

);

-- -----------------------------------------------------------------------------

-- WORLD STATE (append-only once published)

-- -----------------------------------------------------------------------------

CREATE TABLE world_state (

  world_state_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  game_id           UUID NOT NULL REFERENCES wargame_game(game_id),

  version           VARCHAR(50) NOT NULL,

  game_time         VARCHAR(100),

  variables         JSONB,

  is_published      BOOLEAN NOT NULL DEFAULT false,

  published_at      TIMESTAMPTZ,

  published_by      UUID REFERENCES participant(participant_id),

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE (game_id, version)

);

CREATE INDEX idx_world_state_game ON world_state(game_id);

ALTER TABLE turn

  ADD CONSTRAINT fk_turn_resulting_state

  FOREIGN KEY (resulting_state_id) REFERENCES world_state(world_state_id);

CREATE TABLE perceived_situation (

  perceived_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  owner_team_id     UUID NOT NULL REFERENCES player_team(team_id),

  turn_id           UUID REFERENCES turn(turn_id),

  facts             JSONB,

  claims            JSONB,

  information_gaps  TEXT,

  as_of             TIMESTAMPTZ NOT NULL DEFAULT now()

);

-- -----------------------------------------------------------------------------

-- INFORMATION ARTIFACTS & RELEASE

-- -----------------------------------------------------------------------------

CREATE TABLE information_artifact (

  artifact_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  game_id             UUID NOT NULL REFERENCES wargame_game(game_id),

  artifact_type       artifact_type NOT NULL,

  producer_id         UUID REFERENCES participant(participant_id),

  title               VARCHAR(300),

  valid_time_start    TIMESTAMPTZ,

  valid_time_end      TIMESTAMPTZ,

  visibility          VARCHAR(50),

  content_uri         VARCHAR(500),

  version             VARCHAR(30),

  confidence          VARCHAR(30),

  -- subtype-specific (nullable)

  question            TEXT,          -- Assessment

  method              TEXT,          -- Assessment

  finding             TEXT,          -- Assessment / Observation

  observer_id         UUID REFERENCES participant(participant_id), -- Observation

  implication         TEXT,          -- Observation

  headline            VARCHAR(300),  -- WorldNews

  model_version       VARCHAR(50),   -- MSResultPackage

  ms_inputs           JSONB,

  ms_assumptions      TEXT,

  ms_outputs          JSONB,

  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()

);

CREATE INDEX idx_artifact_game_type ON information_artifact(game_id, artifact_type);

CREATE TABLE artifact_chunk (

  chunk_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  artifact_id       UUID NOT NULL REFERENCES information_artifact(artifact_id),

  source_version    VARCHAR(30),

  page              INTEGER,

  offset_start      INTEGER,

  offset_end        INTEGER,

  text_excerpt      TEXT,

  validity          VARCHAR(50),

  visibility        VARCHAR(50)

);

CREATE INDEX idx_chunk_artifact ON artifact_chunk(artifact_id);

CREATE TABLE information_release (

  release_id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  game_id                   UUID NOT NULL REFERENCES wargame_game(game_id),

  turn_id                   UUID REFERENCES turn(turn_id),

  authority_participant_id  UUID REFERENCES participant(participant_id),

  audience_scope            VARCHAR(100),  -- all_players | team_list | control

  release_time              TIMESTAMPTZ NOT NULL,

  conditions                TEXT,

  created_at                TIMESTAMPTZ NOT NULL DEFAULT now()

);

CREATE TABLE release_artifact (

  release_id        UUID NOT NULL REFERENCES information_release(release_id),

  artifact_id       UUID NOT NULL REFERENCES information_artifact(artifact_id),

  PRIMARY KEY (release_id, artifact_id)

);

CREATE TABLE release_audience (

  release_id        UUID NOT NULL REFERENCES information_release(release_id),

  team_id           UUID NOT NULL REFERENCES player_team(team_id),

  PRIMARY KEY (release_id, team_id)

);

-- -----------------------------------------------------------------------------

-- DECISIONS, MOVES, ACTIONS

-- -----------------------------------------------------------------------------

CREATE TABLE strategic_objective (

  objective_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  actor_id          UUID NOT NULL REFERENCES actor(actor_id),

  objective         TEXT NOT NULL,

  priority          INTEGER,

  success_measures  TEXT

);

CREATE TABLE decision (

  decision_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  team_id           UUID NOT NULL REFERENCES player_team(team_id),

  turn_id           UUID REFERENCES turn(turn_id),

  decision_text     TEXT NOT NULL,

  decision_maker_id UUID REFERENCES participant(participant_id),

  rationale         TEXT,

  assumptions       TEXT,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()

);

CREATE TABLE decision_objective (

  decision_id       UUID NOT NULL REFERENCES decision(decision_id),

  objective_id      UUID NOT NULL REFERENCES strategic_objective(objective_id),

  PRIMARY KEY (decision_id, objective_id)

);

CREATE TABLE turn_submission_package (

  package_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  turn_id               UUID NOT NULL REFERENCES turn(turn_id),

  submitting_team_id    UUID NOT NULL REFERENCES player_team(team_id),

  revision              INTEGER NOT NULL DEFAULT 1,

  receipt_status        package_receipt_status NOT NULL DEFAULT 'draft',

  schema_version        VARCHAR(20),

  submitted_at          TIMESTAMPTZ,

  locked_at             TIMESTAMPTZ,

  notes                 TEXT,

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now()

);

CREATE INDEX idx_package_turn_team ON turn_submission_package(turn_id, submitting_team_id);

CREATE TABLE move (

  move_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  package_id        UUID REFERENCES turn_submission_package(package_id),

  team_id           UUID NOT NULL REFERENCES player_team(team_id),

  turn_id           UUID NOT NULL REFERENCES turn(turn_id),

  version           INTEGER NOT NULL DEFAULT 1,

  status            move_status NOT NULL DEFAULT 'draft',

  decision_id       UUID REFERENCES decision(decision_id),

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()

);

CREATE INDEX idx_move_turn ON move(turn_id);

CREATE INDEX idx_move_package ON move(package_id);

CREATE TABLE action (

  action_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  move_id           UUID NOT NULL REFERENCES move(move_id),

  actor_id          UUID REFERENCES actor(actor_id),

  action_class      action_class NOT NULL DEFAULT 'Action',

  statement         TEXT NOT NULL,

  timing            VARCHAR(100),

  location          VARCHAR(200),

  constraints       TEXT,

  -- Military / Combat extensions

  mission           TEXT,

  forces            TEXT,

  area              VARCHAR(200),

  time_window       VARCHAR(100),

  mission_type      VARCHAR(100),

  capability_package TEXT,

  method            TEXT,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()

);

CREATE INDEX idx_action_move ON action(move_id);

CREATE TABLE instrument_of_power (

  iop_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  action_id         UUID NOT NULL REFERENCES action(action_id),

  category          instrument_category NOT NULL,  -- diplomatic | information | military | economic | other

  subcategory       VARCHAR(100),

  responsible_actor_id UUID REFERENCES actor(actor_id)

);

CREATE TABLE dependency (

  dependency_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  move_id           UUID REFERENCES move(move_id),

  action_id         UUID REFERENCES action(action_id),

  type              VARCHAR(50),

  owner             VARCHAR(200),

  deadline          TIMESTAMPTZ,

  status            VARCHAR(30) NOT NULL DEFAULT 'pending',

  CHECK (move_id IS NOT NULL OR action_id IS NOT NULL)

);

CREATE TABLE risk (

  risk_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  move_id           UUID REFERENCES move(move_id),

  action_id         UUID REFERENCES action(action_id),

  statement         TEXT NOT NULL,

  likelihood        VARCHAR(30),

  impact            VARCHAR(30),

  mitigation        TEXT,

  CHECK (move_id IS NOT NULL OR action_id IS NOT NULL)

);

CREATE TABLE desired_effect (

  desired_effect_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  action_id         UUID NOT NULL REFERENCES action(action_id),

  effect            TEXT NOT NULL,

  affected_entity_type VARCHAR(50),

  affected_entity_id   UUID,

  desired_condition TEXT,

  horizon           VARCHAR(50)

);

CREATE TABLE package_artifact (

  package_id        UUID NOT NULL REFERENCES turn_submission_package(package_id),

  artifact_id       UUID NOT NULL REFERENCES information_artifact(artifact_id),

  PRIMARY KEY (package_id, artifact_id)

);

CREATE TABLE move_artifact (

  move_id           UUID NOT NULL REFERENCES move(move_id),

  artifact_id       UUID NOT NULL REFERENCES information_artifact(artifact_id),

  PRIMARY KEY (move_id, artifact_id)

);

-- -----------------------------------------------------------------------------

-- RFI (two-way planning support)

-- -----------------------------------------------------------------------------

CREATE TABLE rfi (

  rfi_id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  requesting_team_id    UUID NOT NULL REFERENCES player_team(team_id),

  turn_id               UUID REFERENCES turn(turn_id),

  question              TEXT NOT NULL,

  topic                 VARCHAR(200),

  priority              rfi_priority DEFAULT 'medium',

  status                rfi_status NOT NULL DEFAULT 'open',

  owner_participant_id  UUID REFERENCES participant(participant_id),

  opened_at             TIMESTAMPTZ NOT NULL DEFAULT now(),

  due_at                TIMESTAMPTZ,

  closed_at             TIMESTAMPTZ,

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now()

);

CREATE INDEX idx_rfi_status ON rfi(status);

CREATE INDEX idx_rfi_team ON rfi(requesting_team_id);

CREATE INDEX idx_rfi_owner ON rfi(owner_participant_id);

CREATE TABLE rfi_response (

  response_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  rfi_id            UUID NOT NULL REFERENCES rfi(rfi_id),

  artifact_id       UUID REFERENCES information_artifact(artifact_id),

  content           TEXT NOT NULL,

  producer_id       UUID REFERENCES participant(participant_id),

  confidence        VARCHAR(30),

  responded_at      TIMESTAMPTZ NOT NULL DEFAULT now()

);

-- -----------------------------------------------------------------------------

-- ADJUDICATION, M&S, COMBAT RESULTS SUPPORT

-- -----------------------------------------------------------------------------

CREATE TABLE adjudication_method (

  method_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  type              VARCHAR(100) NOT NULL,

  version           VARCHAR(30) NOT NULL,

  assumptions       TEXT,

  applicability     TEXT,

  UNIQUE (type, version)

);

CREATE TABLE adjudication_case (

  case_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  move_id           UUID REFERENCES move(move_id),

  action_id         UUID REFERENCES action(action_id),

  adjudicator_id    UUID REFERENCES participant(participant_id),

  ruleset_id        UUID NOT NULL REFERENCES rule_set(ruleset_id),

  method_id         UUID NOT NULL REFERENCES adjudication_method(method_id),

  track             adjudication_track,

  rationale         TEXT,

  status            adjudication_case_status NOT NULL DEFAULT 'open',

  opened_at         TIMESTAMPTZ NOT NULL DEFAULT now(),

  resolved_at       TIMESTAMPTZ,

  CHECK (move_id IS NOT NULL OR action_id IS NOT NULL)

);

CREATE INDEX idx_case_move ON adjudication_case(move_id);

CREATE INDEX idx_case_status ON adjudication_case(status);

CREATE TABLE case_evidence (

  case_id           UUID NOT NULL REFERENCES adjudication_case(case_id),

  artifact_id       UUID NOT NULL REFERENCES information_artifact(artifact_id),

  PRIMARY KEY (case_id, artifact_id)

);

CREATE TABLE combat_resolution_request (

  crr_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  action_id         UUID NOT NULL REFERENCES action(action_id),

  case_id           UUID REFERENCES adjudication_case(case_id),

  method            VARCHAR(100),

  inputs            JSONB,

  status            VARCHAR(30) DEFAULT 'requested',

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()

);

CREATE TABLE ms_run (

  msrun_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  crr_id            UUID REFERENCES combat_resolution_request(crr_id),

  case_id           UUID REFERENCES adjudication_case(case_id),

  model_version     VARCHAR(50),

  configuration     JSONB,

  inputs            JSONB,

  run_time          TIMESTAMPTZ,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()

);

CREATE TABLE combat_results_support (

  crs_id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  case_id               UUID REFERENCES adjudication_case(case_id),

  receiving_team_id     UUID NOT NULL REFERENCES player_team(team_id),

  model_version         VARCHAR(50),

  assumptions           TEXT,

  confidence            VARCHAR(30),

  limitations           TEXT,

  content_artifact_id   UUID REFERENCES information_artifact(artifact_id),

  released_at           TIMESTAMPTZ,

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now()

);

CREATE INDEX idx_crs_team ON combat_results_support(receiving_team_id);

CREATE TABLE outcome (

  outcome_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  case_id           UUID NOT NULL REFERENCES adjudication_case(case_id),

  result            TEXT NOT NULL,

  success_level     success_level,

  rationale         TEXT,

  uncertainty       TEXT,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()

);

CREATE TABLE effect (

  effect_id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  outcome_id            UUID REFERENCES outcome(outcome_id),

  affected_entity_type  VARCHAR(50),

  affected_entity_id    UUID,

  effect_type           VARCHAR(50),

  magnitude             VARCHAR(50),

  duration              VARCHAR(50)

);

CREATE TABLE state_transition (

  transition_id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  from_state_id             UUID NOT NULL REFERENCES world_state(world_state_id),

  to_state_id               UUID NOT NULL REFERENCES world_state(world_state_id),

  authorized_by_case_id     UUID NOT NULL REFERENCES adjudication_case(case_id),

  transition_at             TIMESTAMPTZ NOT NULL DEFAULT now(),

  notes                     TEXT

);

CREATE INDEX idx_transition_from ON state_transition(from_state_id);

CREATE INDEX idx_transition_to ON state_transition(to_state_id);

CREATE TABLE transition_effect (

  transition_id     UUID NOT NULL REFERENCES state_transition(transition_id),

  effect_id         UUID NOT NULL REFERENCES effect(effect_id),

  PRIMARY KEY (transition_id, effect_id)

);

-- -----------------------------------------------------------------------------

-- GAME EVENTS (provenance spine)

-- -----------------------------------------------------------------------------

CREATE TABLE game_event (

  event_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  game_id           UUID NOT NULL REFERENCES wargame_game(game_id),

  turn_id           UUID REFERENCES turn(turn_id),

  event_type        VARCHAR(50) NOT NULL,

  game_time         VARCHAR(100),

  recorded_at       TIMESTAMPTZ NOT NULL DEFAULT now(),

  recorded_by       UUID REFERENCES participant(participant_id),

  payload           JSONB,

  -- optional polymorphic refs

  related_package_id    UUID REFERENCES turn_submission_package(package_id),

  related_case_id       UUID REFERENCES adjudication_case(case_id),

  related_release_id    UUID REFERENCES information_release(release_id),

  related_transition_id UUID REFERENCES state_transition(transition_id),

  related_rfi_id        UUID REFERENCES rfi(rfi_id)

);

CREATE INDEX idx_event_game_turn ON game_event(game_id, turn_id);

CREATE INDEX idx_event_type ON game_event(event_type);

-- -----------------------------------------------------------------------------

-- COMPARTMENTED / PARALLEL ACTIVITIES

-- -----------------------------------------------------------------------------

CREATE TABLE compartmented_interface (

  interface_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  game_id           UUID NOT NULL REFERENCES wargame_game(game_id),

  turn_id           UUID REFERENCES turn(turn_id),

  interface_type    interface_type NOT NULL,

  direction         interface_direction NOT NULL,

  main_stage_ref    VARCHAR(30),

  summary           TEXT,

  provenance_ref    UUID REFERENCES information_artifact(artifact_id),

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  created_by        UUID REFERENCES participant(participant_id)

);

-- -----------------------------------------------------------------------------

-- HELPER VIEWS (optional but useful)

-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_open_rfis AS

SELECT r.*, t.name AS team_name, p.display_name AS owner_name

FROM rfi r

JOIN player_team t ON t.team_id = r.requesting_team_id

LEFT JOIN participant p ON p.participant_id = r.owner_participant_id

WHERE r.status IN ('open', 'assigned', 'escalated');

CREATE OR REPLACE VIEW v_current_world_state AS

SELECT DISTINCT ON (game_id) *

FROM world_state

WHERE is_published = true

ORDER BY game_id, published_at DESC NULLS LAST, created_at DESC;

CREATE OR REPLACE VIEW v_turn_submission_status AS

SELECT

  t.game_id,

  t.turn_id,

  t.turn_number,

  pt.team_id,

  pt.name AS team_name,

  p.package_id,

  p.revision,

  p.receipt_status,

  p.submitted_at,

  p.locked_at

FROM turn t

CROSS JOIN player_team pt

LEFT JOIN turn_submission_package p

  ON p.turn_id = t.turn_id AND p.submitting_team_id = pt.team_id

WHERE pt.game_id = t.game_id;

-- -----------------------------------------------------------------------------

-- COMMENTS (data dictionary lite)

-- -----------------------------------------------------------------------------

COMMENT ON TABLE wargame_game IS 'Bounded wargame event container';

COMMENT ON TABLE world_state IS 'Authoritative, versioned game-world state; published rows are immutable';

COMMENT ON TABLE turn_submission_package IS 'Versioned Turn Card / submission package; locked rows should not be content-updated';

COMMENT ON TABLE rfi IS 'Two-way Request for Information with SLA/owner tracking';

COMMENT ON TABLE combat_results_support IS 'Adjudication-provided advisory M&S/combat support to player cells; not final game effect';

COMMENT ON TABLE state_transition IS 'Authorized change from one published WorldState version to the next';

COMMENT ON TABLE compartmented_interface IS 'Controlled interface between parallel/compartmented activity and main turn flow';

COMMENT ON TABLE game_event IS 'Provenance spine — significant occurrences with optional links to packages, cases, releases, transitions, RFIs';

-- -----------------------------------------------------------------------------

-- Associations, constraints and workflow enforcement.
CREATE TABLE move_rfi (
 move_id uuid NOT NULL REFERENCES move(move_id),
 rfi_id uuid NOT NULL REFERENCES rfi(rfi_id),
 PRIMARY KEY(move_id,rfi_id)
);
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

CREATE FUNCTION wargame_workflow_guard() RETURNS trigger LANGUAGE plpgsql AS $$
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
CREATE TRIGGER workflow_guard BEFORE INSERT OR UPDATE ON turn FOR EACH ROW EXECUTE FUNCTION wargame_workflow_guard();
CREATE TRIGGER workflow_guard BEFORE INSERT OR UPDATE ON turn_submission_package FOR EACH ROW EXECUTE FUNCTION wargame_workflow_guard();
CREATE TRIGGER workflow_guard BEFORE INSERT OR UPDATE ON move FOR EACH ROW EXECUTE FUNCTION wargame_workflow_guard();
CREATE TRIGGER workflow_guard BEFORE INSERT OR UPDATE ON adjudication_case FOR EACH ROW EXECUTE FUNCTION wargame_workflow_guard();
CREATE TRIGGER workflow_guard BEFORE INSERT OR UPDATE ON rfi FOR EACH ROW EXECUTE FUNCTION wargame_workflow_guard();

CREATE FUNCTION wargame_immutable_header() RETURNS trigger LANGUAGE plpgsql AS $$
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
CREATE TRIGGER immutable_header BEFORE INSERT OR UPDATE OR DELETE ON world_state FOR EACH ROW EXECUTE FUNCTION wargame_immutable_header();
CREATE TRIGGER immutable_header BEFORE DELETE ON turn_submission_package FOR EACH ROW EXECUTE FUNCTION wargame_immutable_header();
CREATE TRIGGER immutable_header BEFORE DELETE ON adjudication_case FOR EACH ROW EXECUTE FUNCTION wargame_immutable_header();

-- Resolve all ancestry paths from JSONB rather than referencing nonexistent NEW fields.
-- Parent locks serialize content changes against concurrent header locking/resolution.
CREATE FUNCTION wargame_packages_for_row(tbl text, r jsonb) RETURNS SETOF uuid LANGUAGE plpgsql AS $$
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
CREATE FUNCTION wargame_package_child_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE o jsonb; n jsonb; pid uuid; st text;
BEGIN
 IF TG_OP<>'INSERT' THEN o:=to_jsonb(OLD); END IF;
 IF TG_OP<>'DELETE' THEN n:=to_jsonb(NEW); END IF;
 FOR pid IN SELECT DISTINCT x FROM (
   SELECT wargame_packages_for_row(TG_TABLE_NAME,o) x UNION ALL SELECT wargame_packages_for_row(TG_TABLE_NAME,n) x
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
   EXECUTE format('CREATE TRIGGER package_child_guard BEFORE INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION wargame_package_child_guard()',t);
 END LOOP;
END $$;

CREATE FUNCTION wargame_cases_for_row(tbl text,r jsonb) RETURNS SETOF uuid LANGUAGE plpgsql AS $$
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
CREATE FUNCTION wargame_case_child_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE o jsonb; n jsonb; cid uuid; st text;
BEGIN
 IF TG_OP<>'INSERT' THEN o:=to_jsonb(OLD); END IF;
 IF TG_OP<>'DELETE' THEN n:=to_jsonb(NEW); END IF;
 FOR cid IN SELECT DISTINCT x FROM (
   SELECT wargame_cases_for_row(TG_TABLE_NAME,o) x UNION ALL SELECT wargame_cases_for_row(TG_TABLE_NAME,n) x
 ) q WHERE x IS NOT NULL ORDER BY x LOOP
   SELECT status::text INTO st FROM adjudication_case WHERE case_id=cid FOR UPDATE;
   IF st='resolved' THEN RAISE EXCEPTION 'Resolved case % protects %',cid,TG_TABLE_NAME; END IF;
 END LOOP;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['outcome','effect','case_evidence','ms_run','combat_resolution_request','outcome_desired_effect'] LOOP
   EXECUTE format('CREATE TRIGGER case_child_guard BEFORE INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION wargame_case_child_guard()',t);
 END LOOP;
END $$;
-- transition_effect is a later authorization association: it may be added after resolution.
-- Changes to an outcome/effect itself remain blocked.

-- Validate move/package identity and dual-parent consistency.
CREATE FUNCTION wargame_consistency_guard() RETURNS trigger LANGUAGE plpgsql AS $$
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
   EXECUTE format('CREATE TRIGGER consistency_guard BEFORE INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION wargame_consistency_guard()',t);
 END LOOP;
END $$;

-- Preserve the answered/closed response invariant when response rows are reparented/deleted.
CREATE FUNCTION wargame_response_guard() RETURNS trigger LANGUAGE plpgsql AS $$
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
CREATE TRIGGER response_guard BEFORE UPDATE OR DELETE ON rfi_response FOR EACH ROW EXECUTE FUNCTION wargame_response_guard();

COMMIT;
