from copy import deepcopy
from datetime import datetime,timezone
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import pytest
from jsonschema import Draft202012Validator,FormatChecker
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from validate_turn_card import validate_turn_card
from etl_postgres_to_neo4j import serialize_row,NODE_TABLES,EDGE_SPECS,project_snapshot
SCHEMA=json.loads((ROOT/'GIWG_TurnSubmissionPackage.schema.json').read_text())
CARD=json.loads((ROOT/'sample_valid_turn_card.json').read_text())

def errors(doc,prior=None):return validate_turn_card(doc,SCHEMA,prior)
@pytest.mark.parametrize('filename',list(ROOT.glob('*.schema.json')))
def test_schema_well_formed(filename):Draft202012Validator.check_schema(json.loads(filename.read_text()))
def test_valid_sample():assert not errors(CARD)
def test_invalid_sample():assert errors(json.loads((ROOT/'sample_invalid_turn_card.json').read_text()))
@pytest.mark.parametrize('doc',[[],None,1,'x',{'moves':None},{**CARD,'moves':None},{**CARD,'moves':[None]}])
def test_bad_types_do_not_crash(doc):assert errors(doc)
def test_default_schema_from_other_directory():
 r=subprocess.run([sys.executable,str(ROOT/'validate_turn_card.py'),str(ROOT/'sample_valid_turn_card.json')],cwd='/tmp',capture_output=True,text=True)
 assert r.returncode==0,r.stderr+r.stdout
@pytest.mark.parametrize('field',['statement','mission','forces','method'])
def test_whitespace_rejected(field):
 d=deepcopy(CARD);d['moves'][0]['actions'][0][field]='  '
 assert errors(d)
@pytest.mark.parametrize('field',['mission','forces','method'])
def test_subtype_fields_required(field):
 d=deepcopy(CARD);del d['moves'][0]['actions'][0][field]
 assert errors(d)
def test_missing_submission_timestamp():
 d=deepcopy(CARD);del d['submitted_at'];assert errors(d)
def test_timing_bound():
 d=deepcopy(CARD);d['moves'][0]['actions'][0]['timing']='x'*101;assert errors(d)
def test_dependency_enum():
 d=deepcopy(CARD);d['moves'][0]['actions'][0]['dependencies'][0]['status']='magic';assert errors(d)
def locked():
 d=deepcopy(CARD);d['receipt_status']='locked';d['locked_at']='2026-10-29T15:00:00Z';return d
@pytest.mark.parametrize('old,new',[('submitted','under_adjudication'),('under_adjudication','resolved')])
def test_locked_move_progress(old,new):
 prior=locked();prior['moves'][0]['status']=old
 doc=deepcopy(prior);doc['moves'][0]['status']=new
 assert not errors(doc,prior)
def test_locked_move_regression():
 prior=locked();prior['moves'][0]['status']='resolved'
 doc=deepcopy(prior);doc['moves'][0]['status']='under_adjudication'
 assert errors(doc,prior)
def test_locked_content_edit():
 prior=locked();d=deepcopy(prior);d['moves'][0]['actions'][0]['statement']='Edit';assert errors(d,prior)
def test_locked_header_edit():
 prior=locked();d=deepcopy(prior);d['notes']='Edit';assert errors(d,prior)
def test_no_duplicate_schema_property_errors():
 d=deepcopy(CARD);d['moves'][0]['extra']='x'
 e=errors(d);assert len(e)==1,e
def test_duplicate_move_ids():
 d=deepcopy(CARD);d['moves'].append(deepcopy(d['moves'][0]));assert errors(d)
def test_move_reset_requires_returned():
 prior=deepcopy(CARD);d=deepcopy(prior);d['moves'][0]['status']='draft';assert errors(d,prior)
def test_returned_resubmit_revision_timestamp():
 prior=deepcopy(CARD);prior['receipt_status']='returned';d=deepcopy(prior);d['receipt_status']='submitted'
 assert errors(d,prior)
 d['revision']=2;d['submitted_at']='2026-10-29T16:00:00Z';assert not errors(d,prior)
@pytest.mark.parametrize('status,missing',[('assigned','owner_participant_id'),('closed','closed_at')])
def test_rfi_missing_conditional(status,missing):
 s=json.loads((ROOT/'GIWG_RFI.schema.json').read_text())
 d={'rfi_id':CARD['package_id'],'requesting_team_id':CARD['submitting_team_id'],'question':'Question','status':status,'priority':'medium','opened_at':CARD['submitted_at'],
 'responses':[{'response_id':CARD['package_id'],'content':'Answer','responded_at':CARD['submitted_at']}]}
 assert list(Draft202012Validator(s,format_checker=FormatChecker()).iter_errors(d))
def test_temporal_and_null_serialization():
 r=serialize_row({'t':datetime(2026,10,30,tzinfo=timezone.utc),'nullable':None,'payload':{'a':1}})
 assert r=={'t':'2026-10-30T00:00:00+00:00','nullable':None,'payload':'{"a": 1}'}
def test_every_projected_label_has_edges_and_unique_constraint():
 c=(ROOT/'GIWG_Schema_Neo4j.cypher').read_text()
 labels={x[1] for x in NODE_TABLES}
 touched={x[1] for x in EDGE_SPECS}|{x[4] for x in EDGE_SPECS}
 assert labels<=touched
 for _,label,pk in NODE_TABLES:assert f'(n:{label}) REQUIRE n.{pk} IS UNIQUE' in c
 assert len(NODE_TABLES)==37
 assert c.count('IS UNIQUE;')==38  # 37 projected labels plus one ETL control key
class Result:
 def __init__(self,n):self.n=n
 def single(self):return self.n
 def consume(self):return None
class Tx:
 def __init__(self):self.calls=[]
 def run(self,q,**kwargs):
  self.calls.append((q,kwargs))
  if 'unmanaged' in q:return Result({'n':0})
  if 'count(r)' in q:return Result({'n':0})
  if 'AS matched' in q:return Result({'matched':len(kwargs['pairs'])})
  return Result({})
def test_refresh_is_owned_and_replaces_properties():
 tx=Tx();nodes={t:[] for t,_,_ in NODE_TABLES};nodes['giwg_game']=[{'game_id':'x','name':None}]
 project_snapshot(tx,nodes,[])
 assert any('MATCH (n:GIWGProjection) DETACH DELETE n' in q for q,_ in tx.calls)
 assert any('SET n = row' in q for q,_ in tx.calls)
 assert not any('SET n += row' in q for q,_ in tx.calls)
def test_unmanaged_edges_abort():
 class BadTx(Tx):
  def run(self,q,**kwargs):
   if 'count(r)' in q:return Result({'n':1})
   return super().run(q,**kwargs)
 with pytest.raises(RuntimeError,match='unmanaged'):
  project_snapshot(BadTx(),{t:[] for t,_,_ in NODE_TABLES},[])
