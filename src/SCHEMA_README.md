# Wargame implementation package

Corrected implementation draft, 30 October 2026. PostgreSQL is the source of record;
Neo4j is a disposable read-only projection. This package is not an application,
identity provider, document parser, or an operational authorization system.

## Start with PostgreSQL

Use an empty development database. PostgreSQL 14+ is the intended target;
execution here was against PostgreSQL 18.6 through PGlite, not a standalone server.

```bash
python -m venv .venv
# Linux/macOS: source .venv/bin/activate
# Windows PowerShell: .venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
psql "$WARGAME_PG_DSN" -v ON_ERROR_STOP=1 -f Wargame_Schema_PostgreSQL.sql
python validate_turn_card.py sample_valid_turn_card.json
python validate_turn_card.py sample_invalid_turn_card.json
```

The valid sample should pass; the invalid sample should exit 1. The validator
resolves its default schema relative to its own script, not the working directory.
Schema validation does not insert rows or verify foreign keys. An ingestion service
must normalize nested payloads and insert child records transactionally.

## Initial database installation

This is the initial implementation. Apply Wargame_Schema_PostgreSQL.sql once to an
empty database. There is no prior release or upgrade script in this package.
The schema contains **50 tables**, **3 views**, and **37 projected node classes**.
Relational association tables become graph edges rather than extra nodes.

## Workflow policy

`workflow_rules.json` and SQL `workflow_transition` contain the same matrix; the
execution test checks that they agree. Same-status writes do not represent a
transition and remain subject to content immutability rules.

| Record | Allowed changes |
|---|---|
| Turn | planned → open → locked → adjudicated → closed |
| Package | draft → submitted; submitted → locked or returned; returned → submitted; locked → accepted |
| Move | draft → submitted → under_adjudication → resolved; submitted → draft only with returned package |
| Case | open → in_progress → resolved; resolved → reopened; reopened → in_progress or resolved |
| RFI | open → assigned or escalated; assigned ↔ escalated; assigned/escalated → answered → closed |

New rows must start at planned (turn), draft (package/move), or open (case/RFI).
Import history by replaying reviewed transitions; there is no bypass flag.

Create package content while draft. Set each move to submitted, then submit the
package. Returned resubmissions must increment revision; the database replaces
submitted_at with the actual new submission time. Locking stamps locked_at.

Locked/accepted packages allow move **status-only** progression. Header fields,
actions, instruments, dependencies, risks, desired effects, artifact associations,
and submitted move/RFI associations are protected. Guards check both old and new
parents, including nullable move/action ancestry. Parent row locks prevent a
concurrent child edit from slipping past package locking or case resolution.
Transactions that encounter deadlocks should be retried by the application.

Resolved cases protect outcomes, effects, evidence associations, model runs,
combat requests and evaluated-effect associations. Effects must reference an
outcome. Reopen with a status-only update: the database inserts case_reopened in
the same transaction, recording the database role and assigned adjudicator.
The ingestion service must authenticate/authorize the actual person; the assigned
adjudicator field is not proof of who executed a request. Do not grant application
users table ownership, trigger-disable, TRUNCATE, workflow policy editing, or
superuser privileges. This package does not provision production database roles.

A transition/effect association may be added after case resolution to apply an
already fixed effect. It does not edit the effect or its outcome. Original source
artifacts referenced by frozen links still need an immutable/versioned document
storage policy in the application.

## JSON contract changes

All three schemas remain Draft 2020-12. Use a validator with format checking enabled.
The optional schema_version field is informational and has no hard-coded release label. Subtype requirements,
non-whitespace required text, SQL VARCHAR limits, and conditional required fields
are checked in the JSON contracts. Submitted content fields with semantic rules are
also enforced by the database. Dependency status is now one of pending, satisfied,
blocked, waived; confirm these vocabulary choices with white cell before deployment.

RFIs use `related_move_ids` rather than `related_move_id`. A move's `rfi_ids`
normalizes into the same `move_rfi` association. The many-to-many association allows one move to reference several RFIs and
one RFI to support several moves.

Nested outcome.evaluated_desired_effect_ids normalizes into
`outcome_desired_effect`; the graph projects Outcome-[:EVALUATES]->DesiredEffect.
Insert outcomes/effects before changing a case to resolved. An adjudicated effect
without an outcome is now disallowed; use a separately designed event pathway if
non-adjudicated effects become a real requirement.

## Neo4j projection

Apply `Wargame_Schema_Neo4j.cypher` before running the ETL. It declares **38 uniqueness
constraints: 37 projected entity keys plus 1 refresh control key**. No seed/demo
records are inserted. The relationship catalog is generated from graph_mapping.json.

Supply WARGAME_PG_DSN, WARGAME_NEO4J_URI, WARGAME_NEO4J_USER, WARGAME_NEO4J_PASS and optionally
WARGAME_NEO4J_DATABASE using your environment/secret store. See `.env.example` for
names; the script does not automatically load that file.

```bash
cypher-shell -a "$WARGAME_NEO4J_URI" -u "$WARGAME_NEO4J_USER" -f Wargame_Schema_Neo4j.cypher
python etl_postgres_to_neo4j.py
```

Use a dedicated test graph/database for the first run. Unmarked Neo4j nodes are not automatically deleted; use a fresh test graph for
the initial installation. The new projection is owned through WargameProjection labels and
relationship markers. ETL aborts if it encounters unmanaged relationships touching
owned nodes. Unmarked graph data is untouched.

Full refresh reads a repeatable-read PostgreSQL snapshot and replaces the owned
projection inside one Neo4j transaction. This removes deleted records, stale
relationships, old properties and obsolete subtype labels together. Endpoint count
mismatches roll back the refresh. A PostgreSQL session advisory lock serializes
ETL runs before snapshot capture and stays held through the graph commit.
Null properties are removed using map replacement; timestamps become ISO-8601
strings with T separators, not native Neo4j temporal values. JSON/array columns
are serialized as JSON strings. Large graphs need batching/generations or CDC;
this prototype intentionally holds the snapshot in memory and writes one graph
transaction. It is not a cross-database distributed transaction.

Never write operational updates directly into the graph; manual edits to owned
nodes are replaced on the next refresh. Live Neo4j Community 5.26.0 tests passed: all 38 constraints, graph writes,
repeat refreshes, property/label/deletion cleanup, endpoint-failure rollback,
and unmanaged-data protection. The tested PostgreSQL fixture contained 26 nodes
and 38 relationships. The live graph writer was fed an exported PGlite snapshot;
the complete psycopg-to-standalone-PostgreSQL connection path remains untested.

## Run the checks

```bash
python -m pip install -r requirements-dev.txt
python -m pytest tests/test_validation.py -q
npm ci
npm run test:sql
# With a NEW, EMPTY, disposable Neo4j database and WARGAME_NEO4J_* variables set:
python tests/neo4j_live.py tests/postgres_synthetic_snapshot.json
```

The SQL test uses the real PostgreSQL engine compiled for WebAssembly via PGlite.
It omits pgcrypto/uuid-ossp extension declarations because built-in UUID generation
is available there; standalone server extension installation remains untested.
To regenerate the graph fixture on Linux/macOS:
`WARGAME_SNAPSHOT_OUT=tests/postgres_synthetic_snapshot.json npm run test:sql`.
The live graph test creates constraints and test records, and deliberately deletes
and refreshes owned projection data. It must be run only against a disposable
empty test database. It does not start Neo4j itself.

Tests are synthetic and do not connect to operational databases. Multi-session
concurrency/deadlock behavior and production role grants were not exercised.

## Contents and remaining work

- Wargame_Schema_PostgreSQL.sql: full fresh database installation.
- Three *.schema.json contracts and two sample turn cards.
- validate_turn_card.py, workflow_rules.json: validation and workflow policy.
- etl_postgres_to_neo4j.py, graph_mapping.json, Wargame_Schema_Neo4j.cypher.
- tests/, locked dependency files, TEST_RESULTS.md.

The earlier README referenced an Excel dictionary, requirements DOCX and ontology
JSON that were not supplied here. They were not regenerated or verified. A user
interface, transactional ingestion adapter, identity/authorization integration,
source-document extraction, complete cross-game integrity policy, and production
backup/restore operations remain application/deployment work.
