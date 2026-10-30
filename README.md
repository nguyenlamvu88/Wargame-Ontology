# Wargame Ontology — GIWG

Repository for the GIWG wargame data model and implementation.

The current foundation includes a corrected v1.2 schema, validation, graph
projection and a local development stack. See [development roadmap](docs/ROADMAP.md)
for application features still to build and [contributing](CONTRIBUTING.md) for
change/test guidance.

Local development stack for the corrected GIWG implementation. Includes PostgreSQL,
Neo4j, the Python validator and graph ETL, synthetic demo data, and test commands.
The source implementation and its prior test results are in `src/`.

## Quick start — Windows

Install and start Docker Desktop with Linux containers, then clone/download this repository and open PowerShell in the folder containing
`compose.yaml`.

```powershell
.\setup.ps1
docker compose up -d --build
docker compose run --rm tools smoke-test
```

The setup script creates `.env` with unique random local passwords. If scripts
are restricted on your computer, copy `.env.example` to `.env` and replace both
password placeholders yourself; then run the two Docker commands above.

## Quick start — Linux/macOS

With Docker Engine/Desktop and Compose v2 available:

```bash
sh setup.sh
docker compose up -d --build
docker compose run --rm tools smoke-test
```

Allow several minutes for initial image downloads, the tools image build, and
Neo4j initialization. Allocate roughly 4 GB of memory to Docker for this small
stack. First startup requires internet access for images and Python dependencies.
No prebuilt container images are included in the repository.

Expected final smoke-test output includes:

```text
INTEGRATION PASSED: PostgreSQL -> psycopg -> ETL -> Neo4j; all 37 entity ID sets match
```

That command seeds one clearly named synthetic demo game, runs the actual ETL,
and compares source and graph IDs. Running it again reuses the demo game. It is
intended for this development stack, not an operational database.

## See the graph

Open **http://localhost:7474** in your browser.

- Connection URI: `bolt://localhost:17687`
- Username: `neo4j`
- Password: the `GIWG_NEO4J_PASSWORD` value in your local `.env`.

Run:

```cypher
MATCH (n:GIWGProjection)-[r]->(m:GIWGProjection)
RETURN n, r, m LIMIT 100;
```

The demo follows submission → adjudication → effect → new world state, with an
RFI and an Outcome-[:EVALUATES]->DesiredEffect link. It contains synthetic records
only. A new stack starts empty; data is added when you run demo or smoke-test.

## Commands

| Goal | Command |
|---|---|
| Start databases and initialize schema | `docker compose up -d --build` |
| Inspect startup | `docker compose ps -a` |
| Inspect initialization logs | `docker compose logs bootstrap postgres neo4j` |
| Validate included valid card | `docker compose run --rm tools validate` |
| Validate your own card | `docker compose run --rm tools validate /data/my_card.json` |
| Compare with prior card | `docker compose run --rm tools validate /data/new.json --prior /data/prior.json` |
| Load synthetic demo and refresh graph | `docker compose run --rm tools demo` |
| Refresh graph from PostgreSQL | `docker compose run --rm tools sync` |
| Show database versions and counts | `docker compose run --rm tools status` |
| Run the 38 Python/schema/unit checks | `docker compose run --rm tools test` |
| Seed, run actual ETL, compare graph/source IDs | `docker compose run --rm tools smoke-test` |
| Open PostgreSQL SQL shell | `docker compose exec postgres psql -U giwg -d giwg` |
| Stop while preserving data | `docker compose down` |

Put input JSON in the package's `data/` folder; the tools container reads it at
`/data`. Validation does not ingest records into PostgreSQL. The demo loader is a
synthetic test fixture, not a general Turn Card or OneNote ingestion adapter.

## What runs

| Service | Purpose |
|---|---|
| postgres | PostgreSQL 18.6; corrected SQL initializes an empty data volume |
| neo4j | Neo4j Community 5.26.0; persistent graph data and browser |
| bootstrap | One-shot tools container; checks SQL schema, creates graph constraints and waits for indexes |
| tools | On-demand Python commands; starts after bootstrap completes successfully |

Database healthchecks gate bootstrap. Tools wait for successful bootstrap.
A bootstrap container that exits with code **0** is expected, not a crash.
The Python container runs as an unprivileged user. The PostgreSQL `giwg` account
is the local development administrator; this package does not implement production
application roles or user authentication workflows.

Host ports default to PostgreSQL `15432`, Neo4j Browser `7474`, Bolt `17687`, bound
to loopback only. Change the three port variables in `.env` if they conflict.
Inside the Compose network the tools use `postgres:5432` and `neo4j:7687`.
Host PostgreSQL clients use database/user `giwg` and the PostgreSQL password from
`.env`. Source DSNs are assembled through psycopg's connection-string encoder.

## Persistence and changes

Data lives in named Docker volumes, not inside the repository or disposable tools
containers. Normal shutdown and image rebuilds preserve it.

The PostgreSQL initialization SQL runs only for a **new empty volume**. Editing
that file and restarting a populated volume does not upgrade an existing schema.
`src/migrate_v1_1_to_v1_2.sql` is for a separately managed v1.1 database; do not
apply it to this already initialized v1.2 stack.

The setup scripts never overwrite an existing `.env`. Editing passwords in `.env`
does not rotate credentials in populated database volumes; use database password
change procedures or reset this disposable stack.

To back up PostgreSQL without PowerShell binary-redirection issues:

```text
docker compose exec postgres pg_dump -U giwg -d giwg -Fc -f /tmp/giwg-backup.dump
docker compose cp postgres:/tmp/giwg-backup.dump ./giwg-backup.dump
```

Only to intentionally erase **all development data and graph history**:

```text
docker compose down --volumes
```

Then start again to initialize a clean stack. Do not use that reset as a substitute
for a migration or on data you intend to preserve.

## Testing status

- Compose v2.39.4 accepted the rendered configuration, including the tools profile.
- Python command entry points, valid-card validation and 38 unit/schema checks passed.
- Demo SQL executed against PostgreSQL 18.6 via PGlite and completed the turn/package
  lifecycle with an authorized state transition.
- The underlying implementation previously passed 47 PostgreSQL checks and 18 live
  Neo4j Community 5.26.0 checks (see `src/TEST_RESULTS.md`).
- **Docker Engine is not available in the authoring environment. The image build,
  actual Compose startup, image entrypoints/healthchecks and full containerized
  smoke-test have not been executed here.** Use the smoke-test command above on
  your Docker host to verify the complete standalone PostgreSQL-to-Neo4j path.
- PowerShell setup script was reviewed; PowerShell is not installed here.

This is a backend development package. A player/white-cell interface, general
record ingestion, document extraction, GraphRAG, and production deployment
controls remain separate work. On an air-gapped machine, prebuild/export the
images and transfer them through your approved process; this source checkout by itself
is not an offline image bundle.

## Official configuration references

- [Docker Compose startup order and healthchecks](https://docs.docker.com/compose/how-tos/startup-order/)
- [PostgreSQL official image and initialization behavior](https://hub.docker.com/_/postgres)
- [Neo4j Docker configuration](https://neo4j.com/docs/operations-manual/current/docker/configuration/)


## Automated checks on GitHub

The [GIWG checks workflow](.github/workflows/ci.yml) runs on pushes to main, pull
requests, and manual dispatch. It tests contracts and migrations, builds the tools
image, starts actual PostgreSQL/Neo4j containers, and runs the full smoke-test twice.
Check the repository's **Actions** tab for the current result; a configured workflow
is not a claim that the containerized test has already passed.
