# Shared materials and source evidence

This implements the path **upload → extract → search → cite in a turn card → project
into Neo4j**. Materials are shared within a selected game. The local proof of concept
has no sign-in or per-user permissions; shared does not mean published on the internet.

## Try the complete workflow

1. Run setup if needed, then `docker compose up -d --build`.
2. Open http://localhost:8080. Create an example workspace, or select your existing
   game under **Shared game materials**.
3. Choose a PDF, DOCX, or PPTX, optionally name it, and choose **Upload and extract**.
4. Choose **Review passages**. Check the extracted text and source locations against
   **Download original**. English OCR is used for PDF pages without a text layer.
5. Search for a phrase or keywords. Results are actual source excerpts with document
   title, revision and page/slide/paragraph/table-row locations. Search is lexical
   PostgreSQL full-text search; it does not generate an AI answer.
6. Load a new JSON turn card or use the example draft. Select **Current turn card**
   or a particular move as the citation target, then **Cite this passage**. Materials
   and the card must belong to the same game. Use a new package ID for a new card.
7. Validate and save the card. Its source links and passage citations commit in the
   same transaction as its moves and actions. The saved-card list has **View citations**.
8. Choose **Refresh Neo4j**. Open Neo4j Browser at the configured HTTP port (7474
   by default) and connect to your configured Bolt port (17687 by default).

```cypher
MATCH (m:Move)-[:CITES_PASSAGE]->(c:ArtifactChunk)<-[:HAS_CHUNK]-(d:InformationArtifact)
RETURN m,c,d LIMIT 100;
```

For a package-level citation use `TurnSubmissionPackage` instead of `Move`.
The original file's download path is an app-relative `content_uri` property on the
source artifact. Open it through the Wargame interface, not Neo4j's own web origin.

## What the ontology means

- **InformationArtifact** represents one immutable source revision, not a confirmed
  assertion that everything written in it is true.
- **ArtifactChunk** represents an extracted source passage and its precise location.
- **HAS_CHUNK** connects a source to its passages.
- **CITES_ARTIFACT** / **USES_ARTIFACT** remain the whole-document associations.
- **CITES_PASSAGE** connects a submission package or move to a specific passage.
- **SUPERSEDES** connects consecutive source revisions in the same document family.

Uploading a source never creates Actors, Actions, Outcomes or authoritative WorldState
records. Automatic fact/entity extraction, entity matching, claim approval and AI
question answering remain future work. The graph now connects **documents, evidence
passages and submissions**, rather than automatically interpreting every document fact.

## Data dictionary

The schema has 52 relational tables and 37 projected entity classes. The two new
storage/association tables do not become additional graph node classes.

| Record | Fields / purpose |
| --- | --- |
| information_artifact | Existing document identity and game; new source filename, MIME type, SHA-256, family ID, revision, processing status/error and extraction method |
| document_source | One original byte stream per artifact, retained in PostgreSQL; excluded from graph ETL |
| artifact_chunk | Existing extracted text; new `source_locator` JSON with page/slide/paragraph/table/row/shape, character span, extraction method and ordinal |
| submission_citation | Citation ID, package ID, optional move ID, chunk ID and creation timestamp |

`source_revision` is a document-content revision, not a software release label.
DOCX paragraph numbers refer to top-level body paragraphs; tables have their own
numbering. These are not Word page numbers, which depend on a rendering engine.
PowerPoint citations identify the slide and shape, optionally a table row or notes.
PDF citations identify the physical page, not necessarily its printed page label.
Character offsets refer to normalized extracted text within the source unit, not
raw file bytes. Long units are split into passages of at most 1800 characters.

### Turn-card exchange format

Existing `cited_artifact_ids` still works. Both the package and each move now accept
`cited_chunk_ids`, an array of distinct passage UUIDs. The importer automatically
adds the corresponding whole-source link for each passage citation.

```json
{
  "cited_chunk_ids": ["00000000-0000-4000-8000-000000000001"]
}
```

This is a fragment, not a complete card. Use the UI to select real passage IDs.
Database triggers enforce ready-source status and same-game scope. Composite keys
keep a cited move attached to its package. Locked/accepted packages protect citation
insert/update/delete; uploaded originals and extracted passages are immutable.
Do not bypass these guards by granting users ownership/trigger-disable privileges.

## Source revisions and failures

Choose an existing source under **Document revision** to upload a replacement.
The system creates a new artifact in the same family with an incremented revision;
it never overwrites the old bytes, text or citation IDs. Repeated uploads of identical
bytes in the same game return the existing artifact. Search defaults to the newest
**ready** revision in each family; include earlier revisions to search history.
A failed newer upload does not hide the last ready revision from search.

Extraction is synchronous in an isolated parser subprocess. Original bytes and
`processing` status commit first. Successful extraction commits all passages and
`ready` status together. A failure preserves the original with `failed` status and
an error message; **Retry extraction** retries that same source. An interrupted
process may leave `processing`; retry recovers it. Successful sources are never
reprocessed in place. Save a corrected original as a new revision.

Originals live in the PostgreSQL persistent volume and are included in `pg_dump`.
No separate upload directory or hosted file service is needed. Neo4j remains a
rebuildable projection. Graph refresh is explicit and independent of successful
upload/card persistence; retry the refresh after a graph outage.

## Existing installations: preserve your data

Back up PostgreSQL using the README commands first. Pull/unpack the updated files,
then rebuild and rerun bootstrap:

```bash
docker compose build
docker compose run --rm bootstrap
docker compose up -d --force-recreate web
```

Bootstrap applies `src/migrations/shared_materials.sql` transactionally. It is
additive and repeatable, takes the shared advisory lock, and does not reset volumes.
A fresh database already includes the same DDL in the main SQL installation.
Standalone users apply the migration inside one transaction:

```bash
psql "$WARGAME_PG_DSN" -v ON_ERROR_STOP=1 --single-transaction -f migrations/shared_materials.sql
```

Do not rerun the full initial-install SQL against an existing database. Do not use
`docker compose down --volumes` as an upgrade procedure.

## API

All writes require same-origin JSON. Uploads use base64 file content inside JSON;
the browser handles encoding. Originals are served as downloads, never executed.

| Method / path | Behavior |
| --- | --- |
| POST /api/materials/upload | `game_id`, `filename`, `content_base64`, optional `title`, `prior_artifact_id` |
| POST /api/materials/retry | `artifact_id`; recover failed/interrupted extraction |
| GET /api/materials?game_id=… | Source list including status, revisions and passage counts |
| GET /api/materials/{id} | Source metadata and ordered passages |
| GET /api/materials/{id}/original | Original bytes with download disposition |
| GET /api/passages/{id} | Exact passage, citation location, source and game IDs |
| GET /api/search?game_id=…&q=…&history=true | Up to 50 ranked matching passages; history defaults false |
| GET /api/evidence?package_id=… | Persisted package/move passage citations |

## Limits

- PDF/DOCX/PPTX only. Convert legacy DOC/PPT beforehand; no macro execution.
- 20 MB original; Office expanded total 80 MB / 5000 entries; PDF 200 pages;
  PPTX 300 slides; extracted text 2 million characters / 5000 passages.
- Parser timeout 240 seconds, CPU 180 seconds, address-space limit 1.5 GB on Linux.
  Split large or complex sources. The app remains a single-process local prototype;
  extraction occupies a request and may delay other users. A job queue, streaming
  uploads, authentication, operational authorization and scaling are future work.
- DOCX body paragraphs and tables plus text headers/footers; PPTX text frames,
  grouped shapes, tables and notes. Embedded image/chart interpretation, tracked
  revisions/comments and complex text-box layouts are not guaranteed. Convert
  image-only Office materials to PDF for OCR.
- PDF tables are extracted as page text rather than reconstructed structured tables.
  OCR is English and imperfect. Always inspect source text before relying on it.
- Full-text search uses English stemming and web-search operators. It is not semantic
  retrieval, natural-language reasoning, or an assessment of conflicting sources.

## Validation

```bash
python -m pytest tests -q
npm ci
npm run test:sql
# From Docker repository root:
docker compose run --rm --entrypoint python tools /opt/wargame/web/materials_smoke.py
```

The Docker integration generates synthetic PDF/DOCX/PPTX and a scanned PDF, then
checks extraction, original-byte identity, deduplication, search, game isolation,
transaction rollback, passage evidence, immutable history, revision search, failure
recovery and actual Neo4j CITES_PASSAGE / SUPERSEDES relationships.

## Extraction API references

- https://pypdf.readthedocs.io/en/stable/user/extract-text.html
- https://python-docx.readthedocs.io/en/latest/api/document.html
- https://python-pptx.readthedocs.io/en/latest/user/text.html
