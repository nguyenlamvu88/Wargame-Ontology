# Wargame validation results

Date: 30 October 2026. All fixtures are synthetic.

- Python/schema/extraction tests: 56 checks, including PDF/DOCX/PPTX text/tables,
  scanned-PDF English OCR, parser isolation, container limits, citation JSON contracts,
  source locations, existing workflow validation and graph writer unit checks.
- PostgreSQL 18.6 engine via PGlite 0.5.13: 61 checks. Fresh schema (52 tables),
  in-place migration from the prior foundation, repeat migration with preserved data,
  all existing workflow guards, source/citation immutability, same-game scope,
  move/package scope, full-text search and all graph source queries.
- Docker CI additionally builds the actual image, starts PostgreSQL/Neo4j/web,
  tests JSON card persistence, ingests synthetic PDF/DOCX/PPTX and scanned PDF,
  verifies original bytes, search, revision history, citations and Neo4j paths.
  The current change's CI result is recorded in the repository PR/checks.

The historical standalone Neo4j check remains in tests/neo4j_live.py with its
synthetic snapshot and 18 checks. It is separate from the newer full Docker pipeline.

Not established by these tests: operational authorization, production scale,
malicious-file sandbox certification, multi-user concurrency/deadlock behavior,
complete Office layout/figure interpretation, AI reasoning or fact extraction.
The source parser is resource-bounded local extraction, not an operational
multi-tenant document-processing service. Visual browser verification is separate
from HTTP/API and database checks.
