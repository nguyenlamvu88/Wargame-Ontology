# Changes in v1.2

| Reported issue | Resolution |
|---|---|
| Wrong validator schema filename | Script-relative canonical schema filename |
| Locked moves cannot change processing status | Compare immutable content separately; validate each move transition |
| Four projected classes have no graph edges | Added actor relationship, perceived situation, interface and combat request edges |
| Missing move-level risk/dependency and action-level adjudication links | Added both ancestry paths |
| Missing conditional required keys | Required submitted_at, owner_participant_id and closed_at in applicable branches |
| Unprotected package children | Guard all listed content/association tables; check both old/new parents |
| Case evidence/model runs and null-outcome bypass | Added evidence/run/request guards; effect.outcome_id NOT NULL |
| SQL move regression | Explicit transition matrix and returned-package rule |
| Stale graph properties, labels, records and edges | Atomic owned projection rebuild; preserve nulls and replace properties |
| Invalid root/null input crashes | Stop domain traversal after structural validation failure |
| Whitespace bypass | Schema patterns plus SQL semantic text checks |
| Six graph classes without unique keys | All 37 projected classes constrained, plus one refresh control key |
| Missing EVALUATES persistence | Added outcome_desired_effect table, guard and projection |
| Split action subtype checks | JSON conditional requirements and SQL CHECK constraints |
| Duplicate property errors | Schema owns additionalProperties checks; removed duplicated allowlists |
| Missing move transition comparison | Compare by move_id against validated prior document |
| Cypher version and predicate drift | v1.2 file generated from canonical mapping; removed stale sample |
| Missing SQL state machines | Turn/package/move/case/RFI guards; initial states enforced |
| Returned revision and timestamp | Require increased revision; stamp actual resubmission time |
| SQL length and dependency vocabulary mismatch | JSON maxLength bounds and shared dependency vocabulary |
| RFI cardinality | Deliberately expanded to many-to-many; original one-to-many was internally valid |
| Timestamp serialization | ISO-8601 T-delimited strings |
| Shared trigger references missing fields | JSONB ancestry resolver replaces invalid NEW-field references |
| Reopen event reuse/time-window check | Atomic automatic event insertion on a status-only reopening |
| View blocks RFI column migration | Recreate v_open_rfis around the column change |

Schema compatibility is intentionally breaking for legacy effect rows without
outcomes, invalid subtype content, nonconforming timestamps/statuses and RFI field
names. See README before applying to an existing database. No production data was
changed. Live Neo4j Community 5.26.0 was subsequently tested (18 checks passed).
Standalone PostgreSQL and the full psycopg source-connection path remain untested.
