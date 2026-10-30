# Docker packaging checks — 30 October 2026

Passed:
- Docker Compose v2.39.4 `config --quiet` using supplied configuration.
- Command runner help and default valid-card validation.
- Command runner test: 38 Python/schema/graph-unit checks passed.
- Python source compilation and POSIX setup script syntax check.
- Corrected schema plus the new synthetic demo SQL executed on PostgreSQL 18.6
  through PGlite: 1 game, 1 authorized state transition, closed turn, accepted package.

Inherited implementation validation:
- 45 PostgreSQL execution checks.
- 18 live Neo4j 5.26.0 checks, 26 initial nodes and 38 initial relationships.

Not executed: Docker image build, Compose container startup, healthchecks inside
actual images, full containerized smoke-test, or PowerShell setup execution.
A standalone Compose binary was used for configuration validation; no Docker
Engine/daemon was available. See README for the smoke-test command to run on a
Docker host. The actual live graph tests from the source package are retained.
