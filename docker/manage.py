#!/usr/bin/env python3
"""GIWG container commands. Run `docker compose run --rm tools help`."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import psycopg
from psycopg.conninfo import make_conninfo
from neo4j import GraphDatabase

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'src'
sys.path.insert(0,str(SOURCE))
from etl_postgres_to_neo4j import sync_postgres_to_neo4j,NODE_TABLES


def configure():
    if not os.environ.get('GIWG_PG_DSN'):
        os.environ['GIWG_PG_DSN']=make_conninfo(
            host=os.environ.get('GIWG_PG_HOST','postgres'),
            port=os.environ.get('GIWG_PG_PORT','5432'),
            dbname=os.environ.get('GIWG_PG_DB','giwg'),
            user=os.environ.get('GIWG_PG_USER','giwg'),
            password=os.environ['GIWG_PG_PASSWORD'],connect_timeout=10)
    for key in ['GIWG_PG_PASSWORD','GIWG_NEO4J_PASS']:
        value=os.environ.get(key,'')
        if not value or value.startswith('REPLACE_'):
            raise ValueError('Generate real local passwords using setup.ps1 or setup.sh first')


def graph():
    return GraphDatabase.driver(os.environ['GIWG_NEO4J_URI'],
        auth=(os.environ.get('GIWG_NEO4J_USER','neo4j'),os.environ['GIWG_NEO4J_PASS']),
        connection_timeout=10,max_transaction_retry_time=15)


def bootstrap():
    with psycopg.connect(os.environ['GIWG_PG_DSN']) as pg:
        tables=pg.execute("SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'").fetchone()[0]
        if tables<50:raise RuntimeError('GIWG v1.2 SQL initialization is incomplete; inspect PostgreSQL logs')
        pg.execute('SELECT 1 FROM workflow_transition LIMIT 1').fetchone()
    text=(SOURCE/'GIWG_Schema_Neo4j.cypher').read_text()
    text='\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('//'))
    with graph() as driver,driver.session(database=os.environ.get('GIWG_NEO4J_DATABASE','neo4j')) as session:
        for statement in text.split(';'):
            if statement.strip():session.run(statement).consume()
        session.run('CALL db.awaitIndexes(120)').consume()
    print('BOOTSTRAP PASSED: PostgreSQL schema ready; Neo4j constraints ready')


def seed_demo():
    with psycopg.connect(os.environ['GIWG_PG_DSN']) as pg:
        # Serialize against ETL snapshots and other demo invocations.
        pg.execute('SELECT pg_advisory_xact_lock(719731201)')
        exists=pg.execute('SELECT 1 FROM giwg_game WHERE game_id=%s',('a0000000-0000-4000-8000-000000000001',)).fetchone()
        if exists:
            print('Demo game already exists; no duplicate records inserted')
            return
        pg.execute((ROOT/'docker'/'demo.sql').read_text(),prepare=False)
    print('Demo game inserted: submission, RFI, adjudication, effects and state history')


def status():
    with psycopg.connect(os.environ['GIWG_PG_DSN']) as pg:
        sql_version=pg.execute('SELECT version()').fetchone()[0]
        counts={table:pg.execute(f'SELECT count(*) FROM {table}').fetchone()[0] for table,_,_ in NODE_TABLES}
    with graph() as driver,driver.session(database=os.environ.get('GIWG_NEO4J_DATABASE','neo4j')) as session:
        neo_version=session.run('CALL dbms.components() YIELD versions RETURN versions[0] AS version').single()['version']
        nodes=session.run('MATCH (n:GIWGProjection) RETURN count(n) AS n').single()['n']
        rels=session.run('MATCH (:GIWGProjection)-[r]->(:GIWGProjection) RETURN count(r) AS n').single()['n']
    print(json.dumps({'postgresql':sql_version,'neo4j':neo_version,'source_rows':counts,'graph_nodes':nodes,'graph_relationships':rels},indent=2))


def verify_projection():
    with psycopg.connect(os.environ['GIWG_PG_DSN']) as pg,graph() as driver,driver.session(database=os.environ.get('GIWG_NEO4J_DATABASE','neo4j')) as session:
        for table,label,pk in NODE_TABLES:
            expected={str(r[0]) for r in pg.execute(f'SELECT {pk} FROM {table}').fetchall()}
            actual={r['id'] for r in session.run(f'MATCH (n:GIWGProjection:{label}) WHERE n.{pk} IS NOT NULL RETURN n.{pk} AS id')}
            if actual!=expected:raise RuntimeError(f'Projection IDs differ for {table}')
    print('INTEGRATION PASSED: PostgreSQL -> psycopg -> ETL -> Neo4j; all 37 entity ID sets match')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command',nargs='?',default='help',choices=['help','bootstrap','validate','sync','demo','status','test','smoke-test'])
    args,extra=parser.parse_known_args()
    if args.command=='help':
        print('Commands: bootstrap | validate [json] [--prior json] | sync | demo | status | test | smoke-test')
        print('demo seeds synthetic data and syncs it. smoke-test also compares every projected ID set.')
        return 0
    if args.command=='validate':
        return subprocess.call([sys.executable,str(SOURCE/'validate_turn_card.py'),*(extra or [str(SOURCE/'sample_valid_turn_card.json')])])
    if extra:parser.error('Unexpected arguments: '+' '.join(extra))
    if args.command=='test':
        return subprocess.call([sys.executable,'-m','pytest',str(SOURCE/'tests'/'test_validation.py'),'-q','-p','no:cacheprovider'])
    configure()
    if args.command=='bootstrap':bootstrap()
    elif args.command=='sync':sync_postgres_to_neo4j()
    elif args.command=='status':status()
    elif args.command in {'demo','smoke-test'}:
        bootstrap();seed_demo();sync_postgres_to_neo4j()
        if args.command=='smoke-test':verify_projection()
        status()
    return 0

if __name__=='__main__':
    try:sys.exit(main())
    except Exception as e:
        print(f'FAILED: {type(e).__name__}: {e}',file=sys.stderr)
        sys.exit(1)
