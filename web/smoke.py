"""HTTP + real PostgreSQL/Neo4j integration checks, run inside the tools image."""
import json
import os
import time
import urllib.request
import urllib.error
from copy import deepcopy
from app import configure, connection, uid

BASE=os.environ.get('WARGAME_WEB_URL','http://web:8080')

def request(path, data=None, expected=200):
    req=urllib.request.Request(BASE+path, data=None if data is None else json.dumps(data).encode(), headers={} if data is None else {'Content-Type':'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=120) as response:
            status,body=response.status,response.read()
    except urllib.error.HTTPError as exc:
        status,body=exc.code,exc.read()
    assert status==expected,(path,status,body)
    return json.loads(body)


def count(table):
    with connection() as pg:
        return pg.execute('SELECT count(*) AS n FROM '+table).fetchone()['n']


def main():
    configure()
    for attempt in range(30):
        try:
            request('/api/health')
            break
        except (OSError,AssertionError):
            if attempt==29: raise
            time.sleep(2)
    card=request('/api/example',{})
    # Exercise every nested mapping supported by this example.
    move=card['moves'][0]
    move['dependencies']=[{'type':'access','owner':'Blue team','status':'pending'}]
    move['risks']=[{'statement':'Turn-level uncertainty'}]
    action=move['actions'][0]
    action['dependencies']=[{'type':'transport','owner':'Response unit','status':'satisfied'}]
    action['instruments_of_power']=[{'category':'other','subcategory':'logistics'}]
    artifact=uid()
    card['ms_packages']=[{'artifact_id':artifact,'model_version':'synthetic','inputs':{'quantity':5},'outputs':{'ready':True}}]
    card['cited_artifact_ids']=[artifact]
    move['cited_artifact_ids']=[artifact]
    before={t:count(t) for t in ['turn_submission_package','move','action','risk','dependency','information_artifact','artifact_chunk']}
    request('/api/validate',card)
    assert before=={t:count(t) for t in before}, 'Dry run changed database'
    invalid=deepcopy(card)
    invalid['moves'][0]['actions'][0]['actor_id']=uid()
    request('/api/import',invalid,400)
    assert before=={t:count(t) for t in before}, 'Invalid reference left records'
    # A constraint failure late in the insert must roll back the entire card.
    invalid=deepcopy(card)
    invalid['moves'][0]['actions'][0]['instruments_of_power']*=2
    duplicate=uid()
    for i in invalid['moves'][0]['actions'][0]['instruments_of_power']: i['iop_id']=duplicate
    request('/api/import',invalid,400)
    assert before=={t:count(t) for t in before}, 'Late failure left records'
    request('/api/import',card)
    assert count('turn_submission_package')==before['turn_submission_package']+1
    request('/api/import',card,400)
    with connection() as pg:
        row=pg.execute('SELECT c.text_excerpt FROM artifact_chunk c JOIN information_artifact a USING(artifact_id) WHERE a.title=%s',('Imported turn card '+card['package_id'],)).fetchone()
        assert json.loads(row['text_excerpt'])==card
    submitted=request('/api/example',{})
    submitted['receipt_status']='submitted'
    submitted['submitted_at']='2026-01-01T00:00:00Z'
    submitted['moves'][0]['status']='submitted'
    request('/api/import',submitted)
    with connection() as pg:
        row=pg.execute('SELECT receipt_status,submitted_at FROM turn_submission_package WHERE package_id=%s',(submitted['package_id'],)).fetchone()
        assert row['receipt_status']=='submitted' and row['submitted_at'].year>=2026
    request('/api/import',[],400)
    request('/api/sync',{})
    from manage import graph
    with graph() as driver,driver.session() as session:
        assert session.run('MATCH (n:TurnSubmissionPackage {package_id:$id}) RETURN count(n) AS n',id=card['package_id']).single()['n']==1
    assert any(p['package_id']==card['package_id'] for p in request('/api/overview')['packages'])
    print('WEB INTEGRATION PASSED: HTTP, reference checks, rollback, nested persistence, provenance, duplicate rejection, submission, Neo4j projection')

if __name__=='__main__': main()
