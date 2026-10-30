# Package checks

Date: 30 October 2026. Synthetic data only.

- 56 Python/schema/extraction checks and 61 PostgreSQL engine checks.
- JavaScript syntax and Python compilation checked.
- Docker CI builds the tools/web image, starts the services, runs the full
  PostgreSQL→Neo4j pipeline and the document-ingestion HTTP integration test.
- Ingestion integration covers PDF, DOCX, PPTX, scanned PDF OCR, identical-source
  deduplication, original-byte integrity, source revisions, scoped passage search,
  package/move citations, rollback, locked evidence and Neo4j evidence links.
- The additive migration is tested against the previous foundation with data,
  then applied again to verify repeatability. Volumes are never reset for upgrades.

See the repository's current pull-request checks for the exact Docker run result.
The GitHub Actions workflow is .github/workflows/ci.yml. Local authoring has no
Docker engine; actual container tests run on GitHub's runner. Visual UI verification,
PowerShell execution, production access controls and load testing are not claimed.
