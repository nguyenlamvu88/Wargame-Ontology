// Wargame | PostgreSQL projection | 37 unique node keys
CREATE CONSTRAINT wargame_wargame_game_key IF NOT EXISTS FOR (n:WargameGame) REQUIRE n.game_id IS UNIQUE;
CREATE CONSTRAINT wargame_scenario_key IF NOT EXISTS FOR (n:Scenario) REQUIRE n.scenario_id IS UNIQUE;
CREATE CONSTRAINT wargame_rule_set_key IF NOT EXISTS FOR (n:RuleSet) REQUIRE n.ruleset_id IS UNIQUE;
CREATE CONSTRAINT wargame_turn_key IF NOT EXISTS FOR (n:Turn) REQUIRE n.turn_id IS UNIQUE;
CREATE CONSTRAINT wargame_turn_stage_key IF NOT EXISTS FOR (n:TurnStage) REQUIRE n.stage_id IS UNIQUE;
CREATE CONSTRAINT wargame_participant_key IF NOT EXISTS FOR (n:Participant) REQUIRE n.participant_id IS UNIQUE;
CREATE CONSTRAINT wargame_role_key IF NOT EXISTS FOR (n:Role) REQUIRE n.role_id IS UNIQUE;
CREATE CONSTRAINT wargame_player_team_key IF NOT EXISTS FOR (n:PlayerTeam) REQUIRE n.team_id IS UNIQUE;
CREATE CONSTRAINT wargame_actor_key IF NOT EXISTS FOR (n:Actor) REQUIRE n.actor_id IS UNIQUE;
CREATE CONSTRAINT wargame_capability_key IF NOT EXISTS FOR (n:Capability) REQUIRE n.capability_id IS UNIQUE;
CREATE CONSTRAINT wargame_actor_relationship_key IF NOT EXISTS FOR (n:ActorRelationship) REQUIRE n.relationship_id IS UNIQUE;
CREATE CONSTRAINT wargame_strategic_objective_key IF NOT EXISTS FOR (n:StrategicObjective) REQUIRE n.objective_id IS UNIQUE;
CREATE CONSTRAINT wargame_decision_key IF NOT EXISTS FOR (n:Decision) REQUIRE n.decision_id IS UNIQUE;
CREATE CONSTRAINT wargame_turn_submission_package_key IF NOT EXISTS FOR (n:TurnSubmissionPackage) REQUIRE n.package_id IS UNIQUE;
CREATE CONSTRAINT wargame_move_key IF NOT EXISTS FOR (n:Move) REQUIRE n.move_id IS UNIQUE;
CREATE CONSTRAINT wargame_action_key IF NOT EXISTS FOR (n:Action) REQUIRE n.action_id IS UNIQUE;
CREATE CONSTRAINT wargame_instrument_of_power_key IF NOT EXISTS FOR (n:InstrumentOfPower) REQUIRE n.iop_id IS UNIQUE;
CREATE CONSTRAINT wargame_dependency_key IF NOT EXISTS FOR (n:Dependency) REQUIRE n.dependency_id IS UNIQUE;
CREATE CONSTRAINT wargame_risk_key IF NOT EXISTS FOR (n:Risk) REQUIRE n.risk_id IS UNIQUE;
CREATE CONSTRAINT wargame_desired_effect_key IF NOT EXISTS FOR (n:DesiredEffect) REQUIRE n.desired_effect_id IS UNIQUE;
CREATE CONSTRAINT wargame_information_artifact_key IF NOT EXISTS FOR (n:InformationArtifact) REQUIRE n.artifact_id IS UNIQUE;
CREATE CONSTRAINT wargame_artifact_chunk_key IF NOT EXISTS FOR (n:ArtifactChunk) REQUIRE n.chunk_id IS UNIQUE;
CREATE CONSTRAINT wargame_information_release_key IF NOT EXISTS FOR (n:InformationRelease) REQUIRE n.release_id IS UNIQUE;
CREATE CONSTRAINT wargame_rfi_key IF NOT EXISTS FOR (n:RFI) REQUIRE n.rfi_id IS UNIQUE;
CREATE CONSTRAINT wargame_rfi_response_key IF NOT EXISTS FOR (n:RFIResponse) REQUIRE n.response_id IS UNIQUE;
CREATE CONSTRAINT wargame_world_state_key IF NOT EXISTS FOR (n:WorldState) REQUIRE n.world_state_id IS UNIQUE;
CREATE CONSTRAINT wargame_perceived_situation_key IF NOT EXISTS FOR (n:PerceivedSituation) REQUIRE n.perceived_id IS UNIQUE;
CREATE CONSTRAINT wargame_game_event_key IF NOT EXISTS FOR (n:GameEvent) REQUIRE n.event_id IS UNIQUE;
CREATE CONSTRAINT wargame_adjudication_method_key IF NOT EXISTS FOR (n:AdjudicationMethod) REQUIRE n.method_id IS UNIQUE;
CREATE CONSTRAINT wargame_adjudication_case_key IF NOT EXISTS FOR (n:AdjudicationCase) REQUIRE n.case_id IS UNIQUE;
CREATE CONSTRAINT wargame_combat_resolution_request_key IF NOT EXISTS FOR (n:CombatResolutionRequest) REQUIRE n.crr_id IS UNIQUE;
CREATE CONSTRAINT wargame_ms_run_key IF NOT EXISTS FOR (n:MSRun) REQUIRE n.msrun_id IS UNIQUE;
CREATE CONSTRAINT wargame_combat_results_support_key IF NOT EXISTS FOR (n:CombatResultsSupport) REQUIRE n.crs_id IS UNIQUE;
CREATE CONSTRAINT wargame_outcome_key IF NOT EXISTS FOR (n:Outcome) REQUIRE n.outcome_id IS UNIQUE;
CREATE CONSTRAINT wargame_effect_key IF NOT EXISTS FOR (n:Effect) REQUIRE n.effect_id IS UNIQUE;
CREATE CONSTRAINT wargame_state_transition_key IF NOT EXISTS FOR (n:StateTransition) REQUIRE n.transition_id IS UNIQUE;
CREATE CONSTRAINT wargame_compartmented_interface_key IF NOT EXISTS FOR (n:CompartmentedInterface) REQUIRE n.interface_id IS UNIQUE;

CREATE CONSTRAINT wargame_projection_control_key IF NOT EXISTS FOR (n:WargameProjectionControl) REQUIRE n.name IS UNIQUE;

// Semantic relationship catalog (generated from graph_mapping.json):
// APPLIES_EFFECT
// AS_OF_TURN
// AUTHORIZED_BY
// BELONGS_TO_TURN
// CITES_ARTIFACT
// CONSIDERS
// CONTAINS
// CONTAINS_MOVE
// CONTRIBUTES_TO
// CONTROLS
// DELIVERS_SUPPORT_TO
// EVALUATES
// FROM_ACTOR
// FROM_STATE
// GENERATED_UNDER
// HAS_ACTOR_RELATIONSHIP
// HAS_CAPABILITY
// HAS_CHUNK
// HAS_DEPENDENCY
// HAS_INTERFACE
// HAS_MEMBER
// HAS_RISK
// HAS_SCENARIO
// HAS_STAGE
// HAS_TEAM
// HAS_TURN
// IS_ADJUDICATED_BY
// IS_ASSIGNED
// IS_DELIVERED_TO
// IS_FORMALIZED_IN
// MAINTAINS_STATE_HISTORY
// MAKES
// OWNED_BY
// PERCEIVED_BY
// PERFORMED_BY
// PRODUCES
// PURSUES
// RECORDS
// RELATED_TO_MOVE
// RELEASES
// REPRESENTS
// REQUESTED_BY
// RESOLVES_ACTION
// RESPONDS_TO
// SEEKS
// SUBMITS
// SUBMITS_PACKAGE
// SUPPORTS
// TO_ACTOR
// TO_STATE
// USES
// USES_ARTIFACT
// USES_INSTRUMENT
// USES_RULE_SET
// USES_RUN
// USES_VERSIONED_METHOD
// USES_VERSIONED_RULES

// No seed data. Use PostgreSQL as the source of record.
