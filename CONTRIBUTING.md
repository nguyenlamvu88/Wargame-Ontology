# Working on this repository

Use a feature branch and pull request for subsequent changes. Include the reason
for the change, user-visible behavior, and relevant test results.

For local Python checks:

```bash
python -m pip install -r src/requirements-dev.txt
python -m pytest src/tests/test_validation.py -q
```

For the PostgreSQL engine and migration tests:

```bash
cd src
npm ci
npm run test:sql
```

For the complete Docker pipeline, follow the setup instructions in README and run:

```bash
docker compose run --rm tools smoke-test
```

Schema changes must include a migration and keep JSON contracts, SQL workflow
rules, workflow_rules.json and graph_mapping.json consistent. Keep secrets, `.env`
files, database dumps and operational records out of commits. Synthetic examples
belong in tests or the demo fixture.
