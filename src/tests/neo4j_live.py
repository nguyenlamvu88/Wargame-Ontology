"""Live Neo4j integration checks. Uses a fresh, disposable database only.
Usage: GIWG_NEO4J_URI=... GIWG_NEO4J_PASS=... python tests/neo4j_live.py snapshot.json
Generate snapshot with GIWG_SNAPSHOT_OUT=... npm run test:sql first.
"""
from copy import deepcopy
import json
import os
from pathlib import Path
import sys
import time
from uuid import uuid4
from neo4j import GraphDatabase
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from etl_postgres_to_neo4j import project_snapshot,serialize_row

snapshot=json.loads(Path(sys.argv[1]).read_text())
nodes={k:[serialize_row(r) for r in v] for k,v in snapshot['nodes'].items()}
edges=snapshot['edges']
passed=0

def check(value,label):
 global passed
 if not value:raise AssertionError(label)
 passed+=1;print('PASS',label,flush=True)

with GraphDatabase.driver(os.environ['GIWG_NEO4J_URI'],auth=(os.environ.get('GIWG_NEO4J_USER','neo4j'),os.environ['GIWG_NEO4J_PASS']),max_transaction_retry_time=0,connection_timeout=2) as driver:
 for i in range(60):
  try:
   driver.verify_connectivity();break
  except Exception:
   if i==59:raise
   time.sleep(0.5)
 with driver.session(database='neo4j') as session:
  def one(q,**p):return session.run(q,**p).single()[0]
  print('ENGINE',one('CALL dbms.components() YIELD versions RETURN versions[0]'),flush=True)
  check(one('MATCH (n) RETURN count(n)')==0,'fresh disposable Neo4j database')
  text=(ROOT/'GIWG_Schema_Neo4j.cypher').read_text()
  text='\n'.join(l for l in text.splitlines() if not l.lstrip().startswith('//'))
  for statement in text.split(';'):
   if statement.strip():session.run(statement).consume()
  session.run('CALL db.awaitIndexes(60)').consume()
  check(one('SHOW CONSTRAINTS YIELD name RETURN count(name)')==38,'all 38 Cypher constraints execute')
  result=session.execute_write(project_snapshot,nodes,edges)
  expected=sum(len(v) for v in nodes.values())
  check(one('MATCH (n:GIWGProjection) RETURN count(n)')==expected,'PostgreSQL snapshot nodes projected')
  expected_edges=sum(len(pairs) for spec,pairs in edges)
  check(one('MATCH (:GIWGProjection)-[r]->(:GIWGProjection) RETURN count(r)')==expected_edges,'all PostgreSQL snapshot edge pairs projected')
  check(one('MATCH (:Outcome)-[:EVALUATES]->(:DesiredEffect) RETURN count(*)')>0,'outcome-to-desired-effect relationship exists')
  check(one('MATCH (:Move)-[:HAS_RISK]->(:Risk) RETURN count(*)')>0,'move-level risk relationship exists')
  session.execute_write(project_snapshot,nodes,edges)
  check(one('MATCH (n:GIWGProjection) RETURN count(n)')==expected,'repeat refresh has no duplicate nodes')
  check(one('MATCH (:GIWGProjection)-[r]->(:GIWGProjection) RETURN count(r)')==expected_edges,'repeat refresh has no duplicate edges')
  # Ensure actual unique constraints reject duplicate source IDs.
  try:
   session.run('CREATE (:GIWGGame {game_id:$id})',id=nodes['giwg_game'][0]['game_id']).consume()
   raise AssertionError('duplicate ID allowed')
  except Exception as e:
   check('Constraint' in type(e).__name__ or 'Constraint' in str(e),'duplicate IDs rejected by live constraint')
  changed=deepcopy(nodes)
  action=changed['action'][0]
  action.update(action_class='CombatAction',mission='Synthetic mission',forces='Synthetic forces',method='Synthetic method',location='Test location')
  session.execute_write(project_snapshot,changed,edges)
  check(one('MATCH (a:CombatAction:MilitaryAction {action_id:$id}) RETURN count(a)',id=action['action_id'])==1,'subtype labels applied')
  action['action_class']='Action';action['location']=None
  session.execute_write(project_snapshot,changed,edges)
  check(one('MATCH (a:Action {action_id:$id}) RETURN a.location IS NULL AND NOT a:CombatAction AND NOT a:MilitaryAction',id=action['action_id']),'obsolete labels and NULL properties removed')
  removed=deepcopy(changed);rid=removed['risk'][0]['risk_id'];removed['risk']=removed['risk'][1:]
  trimmed=[(spec,[p for p in pairs if p['src']!=rid and p['tgt']!=rid]) for spec,pairs in edges]
  session.execute_write(project_snapshot,removed,trimmed)
  check(one('MATCH (r:Risk {risk_id:$id}) RETURN count(r)',id=rid)==0,'deleted source row removed')
  check(one('MATCH (:GIWGProjection)-[r]->(:GIWGProjection) RETURN count(r)')==sum(len(p) for _,p in trimmed),'stale relationships removed')
  # Force a missing graph endpoint: preceding DELETE/CREATE work must roll back.
  broken=deepcopy(trimmed)
  for spec,pairs in broken:
   if pairs:
    pairs[0]['tgt']=str(uuid4());break
  try:
   session.execute_write(project_snapshot,removed,broken)
   raise AssertionError('missing endpoint accepted')
  except RuntimeError as e:
   check('Unmatched' in str(e),'missing endpoints detected by live writer')
  check(one('MATCH (n:GIWGProjection) RETURN count(n)')==expected-1,'failed refresh rolls back node replacement')
  check(one('MATCH (:Outcome)-[:EVALUATES]->(:DesiredEffect) RETURN count(*)')>0,'failed refresh preserves previous relationships')
  session.run('CREATE (:ExternalTest {name:"unmanaged"})').consume()
  session.run('MATCH (g:GIWGGame),(x:ExternalTest) CREATE (g)-[:EXTERNAL_TEST]->(x)').consume()
  try:
   session.execute_write(project_snapshot,removed,trimmed)
   raise AssertionError('unmanaged edge accepted')
  except RuntimeError as e:check('unmanaged' in str(e),'unmanaged relationship aborts live refresh')
  check(one('MATCH (:ExternalTest) RETURN count(*)')==1,'unmanaged node preserved')
  print(f'RESULT: {passed} live Neo4j checks passed; {expected} initial nodes, {expected_edges} initial relationships',flush=True)
