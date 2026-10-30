# Wargame validation results

Date: 30 October 2026

## Executed PostgreSQL tests: 45 passed

Engine: PostgreSQL 18.6 through PGlite 0.5.13 (WebAssembly). Actual DDL, PL/pgSQL
triggers, constraints, inserts, updates, deletes and graph source SELECTs executed
against temporary in-memory databases. No production databases were contacted.

Covered:
- Fresh schema creation: 50 tables.
- Valid turn, package, move, case and RFI workflow behavior.
- Invalid skipped stages and initial states.
- Returned-package revision increment and timestamp replacement.
- Locked action edits now raise the intended protection exception, not a missing-field runtime error.
- Old-parent reparenting bypasses for moves, actions, dependencies, effects and model runs.
- Protected instruments, risks, desired effects and artifact associations.
- Status-only move advancement; regressions rejected.
- Published world-state update/delete prevention.
- Required combat subtype fields and whitespace rejection.
- Resolved case outcome/effect/evidence/model-run/evaluation association protection.
- NULL-outcome effect insertion rejected.
- Automatic atomic reopening audit event and reopened-case edits.
- Required RFI owner/response, and last-response deletion prevention.
- SQL and Python transition matrix agreement.
- Every graph edge source SELECT against the corrected SQL schema.

## Python/schema/graph-unit tests: 38 passed

Covered: all three schema definitions; valid/invalid sample cards; wrong JSON root
and nested types; default filename independent of working directory; conditional
required fields; subtype completeness; whitespace; VARCHAR bounds; dependency
vocabulary; locked header/content immutability; permitted move advancement;
regression/reset rules; revision/timestamp rules; uniqueness; ISO timestamp/null
serialization; coverage of all projected labels/constraints; graph refresh ownership
and property-replacement behavior; unmanaged-edge abort.

Those Python graph unit tests use a test double. Separate live integration tests
were subsequently executed as described below.

## Live Neo4j integration tests: 18 passed

Engine: Neo4j Community 5.26.0 on Java 17, running locally in a temporary instance.
The distribution launcher could not locate its Java executable in this environment;
starting the normal CommunityEntryPoint directly resolved that startup problem.
The database was bound to loopback, used only synthetic records, and was stopped
after testing.

Executed the actual supplied Cypher constraints and the actual `project_snapshot`
function over a Bolt connection. The source data was exported from the PGlite SQL
test: **26 nodes and 38 relationships**. All 37 entity constraints plus the ETL
control constraint were created (38 constraints total).

Verified:
- Actual node and relationship creation, EVALUATES, and move-level risks.
- Repeated refresh without duplicate nodes or relationships.
- Uniqueness constraint rejects duplicate source IDs.
- Military/combat labels are applied, and obsolete subtype labels removed.
- Source NULL updates remove graph properties.
- Deleted source nodes and stale relationships disappear.
- Missing endpoint aborts and rolls back graph replacement, preserving prior data.
- Unmanaged graph relationships abort refresh and unmanaged nodes survive.

Repeat with `python tests/neo4j_live.py tests/postgres_synthetic_snapshot.json`
against a fresh disposable Neo4j database with WARGAME_NEO4J_* environment variables.
The fixture is synthetic and contains no operational data.

## Additional checks

- Both Python source files compiled successfully.
- Canonical valid card passed the CLI validator.
- Canonical invalid card was rejected.
- Dependency versions captured in requirements files and npm lockfile.

## Not tested

Standalone PostgreSQL installation/extensions, the full psycopg-to-PostgreSQL
ETL source-connection path, cross-database retry behavior, multi-session concurrency, operational
access controls, document parsing, production scale, and reconciliation of the
unprovided Excel dictionary/requirements document/ontology catalog.

No claim of operational deployment readiness is made. The package is a tested
initial implementation with repeatable checks.
