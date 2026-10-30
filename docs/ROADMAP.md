# Development roadmap

This repository begins with the GIWG database and Docker foundation.

## Foundation included

- PostgreSQL schema, workflow triggers, immutability rules.
- Turn Card, RFI and adjudication JSON contracts.
- Turn Card CLI validation and graph projection.
- Docker Compose services, synthetic demo and end-to-end smoke-test command.
- GitHub Actions for unit/contract checks, PostgreSQL engine checks and live
  containerized PostgreSQL-to-Neo4j integration.

## Application work to implement next

1. Transactional Turn Card ingestion API with reviewed import mapping.
2. Player and white-cell forms with role-based visibility and permissions.
3. RFI ownership, responses and status workflow.
4. Adjudication review, recorded rationale and outcome/effect entry.
5. Versioned document ingestion from existing OneNote/PDF/DOCX records.
6. Operational state-history and evidence views.
7. Deployment-specific identity integration, production database roles and backups.

A passing foundation test is not evidence that the future application features
already exist. Only synthetic demonstration records are included.
