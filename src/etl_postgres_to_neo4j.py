#!/usr/bin/env python3
"""Atomically rebuild the GIWGProjection-owned graph from a repeatable-read snapshot.

Prototype full-refresh mode: the projection is read-only/disposable. Manual edits on
GIWGProjection nodes are intentionally replaced. Unmarked graph data is untouched.
For large deployments use a generation/CDC design instead of one large transaction.
"""
from datetime import date, datetime, timezone
from decimal import Decimal
import json
import os
from pathlib import Path
from uuid import UUID
import psycopg
from psycopg.rows import dict_row
from neo4j import GraphDatabase

MAPPING=json.loads((Path(__file__).resolve().parent/'graph_mapping.json').read_text())
NODE_TABLES=[tuple(x) for x in MAPPING['nodes']]
EDGE_SPECS=[tuple(x) for x in MAPPING['edges']]
ARTIFACT_SUBTYPE_LABELS={
 'assessment':['Assessment'], 'observation':['Assessment','Observation'],
 'news':['WorldNews'], 'evidence':['EvidenceArtifact'],
 'ms_result':['EvidenceArtifact','MSResultPackage'],
 'analysis_product':['AnalysisProduct'], 'rfi_response':['RFIResponse'],
}

def serialize_value(v):
    if v is None or isinstance(v,(str,int,float,bool)):
        return v
    if isinstance(v,datetime):
        if v.tzinfo is not None:
            v=v.astimezone(timezone.utc)
        return v.isoformat()
    if isinstance(v,date):return v.isoformat()
    if isinstance(v,(UUID,Decimal)):return str(v)
    if isinstance(v,(dict,list)):return json.dumps(v,default=serialize_value,sort_keys=True)
    raise TypeError(f'Unsupported PostgreSQL value: {type(v).__name__}')

def serialize_row(row):
    # Preserve nulls. SET n = row replaces properties rather than accumulating them.
    return {k:serialize_value(v) for k,v in row.items()}

def project_snapshot(tx,nodes,edges):
    # A write lock on a dedicated marker serializes concurrent ETL jobs.
    tx.run("MERGE (p:GIWGProjectionControl {name:'giwg-v1.2'}) SET p.locked_at=datetime() ").consume()
    # Do not detach-delete edges belonging to some other application.
    external=tx.run('MATCH (n:GIWGProjection)-[r]-() WHERE coalesce(r.giwg_projection,false)=false RETURN count(r) AS n').single()['n']
    if external:
        raise RuntimeError('Projection has unmanaged relationships; detach or migrate these explicitly first')
    tx.run('MATCH (n:GIWGProjection) DETACH DELETE n').consume()
    for table,label,pk in NODE_TABLES:
        rows=nodes[table]
        if rows:
            tx.run(f'UNWIND $rows AS row CREATE (n:GIWGProjection:{label}) SET n = row',rows=rows).consume()
    tx.run("MATCH (a:GIWGProjection:Action) WHERE a.action_class IN ['MilitaryAction','CombatAction'] SET a:MilitaryAction").consume()
    tx.run("MATCH (a:GIWGProjection:Action) WHERE a.action_class='CombatAction' SET a:CombatAction").consume()
    tx.run('MATCH (a:GIWGProjection:Actor) WHERE a.is_coalition=true SET a:Coalition').consume()
    for subtype,labels in ARTIFACT_SUBTYPE_LABELS.items():
        tx.run(f"MATCH (n:GIWGProjection:InformationArtifact) WHERE n.artifact_type=$subtype SET n:{':'.join(labels)}",subtype=subtype).consume()
    for spec,pairs in edges:
        _,sl,sp,rel,tl,tp=spec
        if not pairs:continue
        result=tx.run(f'''UNWIND $pairs AS pair
          MATCH (s:GIWGProjection:{sl} {{{sp}:pair.src}})
          MATCH (t:GIWGProjection:{tl} {{{tp}:pair.tgt}})
          MERGE (s)-[r:{rel}]->(t) SET r.giwg_projection=true
          RETURN count(*) AS matched''',pairs=pairs).single()
        if result['matched']!=len(pairs):
            raise RuntimeError(f'Unmatched graph endpoints for {rel}; whole refresh rolled back')
    return {'nodes':sum(len(v) for v in nodes.values()),'edge_pairs':sum(len(v) for _,v in edges)}

def sync_postgres_to_neo4j():
    # Required configuration, no embedded passwords or production-default DSN.
    dsn=os.environ['GIWG_PG_DSN']
    uri=os.environ['GIWG_NEO4J_URI']
    user=os.environ['GIWG_NEO4J_USER']
    password=os.environ['GIWG_NEO4J_PASS']
    # A PostgreSQL session advisory lock is acquired before taking the snapshot,
    # and held through the graph commit. Concurrent runs cannot publish stale
    # snapshots out of order. A disconnected process releases this lock.
    with psycopg.connect(dsn,row_factory=dict_row,autocommit=True) as pg:
        pg.execute('SELECT pg_advisory_lock(719731201)')
        try:
            with pg.transaction():
                pg.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY')
                nodes={table:[serialize_row(r) for r in pg.execute(f'SELECT * FROM {table}').fetchall()] for table,_,_ in NODE_TABLES}
                edges=[]
                for spec in EDGE_SPECS:
                    pairs=[{'src':str(r['src']),'tgt':str(r['tgt'])} for r in pg.execute(spec[0]).fetchall()]
                    edges.append((spec,pairs))
            with GraphDatabase.driver(uri,auth=(user,password)) as driver:
                database=os.environ.get('GIWG_NEO4J_DATABASE','neo4j')
                with driver.session(database=database) as session:
                    print(session.execute_write(project_snapshot,nodes,edges))
        finally:
            pg.execute('SELECT pg_advisory_unlock(719731201)')

if __name__=='__main__':
    sync_postgres_to_neo4j()
