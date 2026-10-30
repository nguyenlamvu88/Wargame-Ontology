"""Full real-service document -> search -> citation -> graph regression test."""
import base64
from copy import deepcopy
import hashlib
import sys
import urllib.request
from urllib.parse import quote
from app import configure, connection, uid
from smoke import request, BASE
sys.path.insert(0,str(__import__('pathlib').Path(__file__).resolve().parents[1]/'src/tests'))
from material_fixtures import docx_bytes,pptx_bytes,pdf_bytes,scanned_pdf_bytes


def main():
    configure()
    card=request('/api/example',{})
    context=next(c for c in request('/api/overview')['contexts'] if c['turn_id']==card['turn_id'])
    game=context['game_id']
    def upload(filename,data,prior=None,game_id=game):
        return request('/api/materials/upload',{'game_id':game_id,'filename':filename,'content_base64':base64.b64encode(data).decode(),'prior_artifact_id':prior})
    first_bytes=docx_bytes()
    source=upload('Scenario.docx',first_bytes)
    assert source['material']['processing_status']=='ready',source
    aid=source['material']['artifact_id']
    assert upload('Duplicate.docx',first_bytes)['material']['artifact_id']==aid
    with urllib.request.urlopen(BASE+'/api/materials/'+aid+'/original') as response:
        assert response.read()==first_bytes
        assert 'attachment' in response.headers['Content-Disposition']
    assert source['material']['source_sha256']==hashlib.sha256(first_bytes).hexdigest()
    result=request('/api/search?game_id='+game+'&q=supply')
    passage=next(r for r in result['results'] if r['artifact_id']==aid)
    assert 'paragraph' in passage['citation']
    chunk=passage['chunk_id']
    assert request('/api/passages/'+chunk)['text_excerpt']==passage['text_excerpt']
    for filename,maker in [('Rules.pdf',pdf_bytes),('Brief.pptx',pptx_bytes),('Scanned.pdf',scanned_pdf_bytes)]:
        material=upload(filename,maker())
        assert material['material']['processing_status']=='ready',material
        if filename=='Scanned.pdf': assert 'pdf-ocr-eng' in material['material']['extraction_method']
    card['cited_chunk_ids']=[chunk]
    card['moves'][0]['cited_chunk_ids']=[chunk]
    request('/api/validate',card)
    with connection() as pg:
        assert not pg.execute('SELECT 1 FROM submission_citation WHERE package_id=%s',(card['package_id'],)).fetchone()
    request('/api/import',card)
    citations=request('/api/evidence?package_id='+card['package_id'])['citations']
    assert len(citations)==2 and all(c['chunk_id']==chunk for c in citations)
    other=request('/api/example',{})
    other_context=next(c for c in request('/api/overview')['contexts'] if c['turn_id']==other['turn_id'])
    assert not request('/api/search?game_id='+other_context['game_id']+'&q=supply')['results']
    other['cited_chunk_ids']=[chunk]
    request('/api/import',other,400)
    with connection() as pg:
        assert not pg.execute('SELECT 1 FROM turn_submission_package WHERE package_id=%s',(other['package_id'],)).fetchone()
        pg.execute("UPDATE move SET status='submitted' WHERE package_id=%s",(card['package_id'],))
        pg.execute("UPDATE turn_submission_package SET receipt_status='submitted' WHERE package_id=%s",(card['package_id'],))
        pg.execute("UPDATE turn_submission_package SET receipt_status='locked' WHERE package_id=%s",(card['package_id'],))
    try:
        with connection() as pg: pg.execute('DELETE FROM submission_citation WHERE package_id=%s',(card['package_id'],))
    except __import__('psycopg').Error: pass
    else: raise AssertionError('Locked evidence deleted')
    revision=upload('Scenario updated.docx',docx_bytes('Revised scenario: the depot is closed.'),aid)
    assert revision['material']['source_revision']==2
    assert revision['material']['source_family_id']==source['material']['source_family_id']
    current=request('/api/search?game_id='+game+'&q=supply')['results']
    assert all(r['artifact_id']!=aid for r in current)
    history=request('/api/search?game_id='+game+'&q=supply&history=true')['results']
    assert any(r['artifact_id']==aid for r in history)
    assert request('/api/passages/'+chunk)['text_excerpt']==passage['text_excerpt'], 'Old citation changed after new revision'
    # Valid PDF header but unreadable body: original retained with actionable status.
    failed=upload('Broken.pdf',b'%PDF-1.4\nnot a readable PDF')
    assert failed['material']['processing_status']=='failed'
    retried=request('/api/materials/retry',{'artifact_id':failed['material']['artifact_id']})
    assert retried['material']['processing_status']=='failed'
    request('/api/materials/upload',{'game_id':game,'filename':'x.doc','content_base64':'eA=='},400)
    request('/api/sync',{})
    from manage import graph
    with graph() as driver,driver.session() as session:
        row=session.run('''MATCH (p:TurnSubmissionPackage {package_id:$pid})-[:CITES_PASSAGE]->(c:ArtifactChunk {chunk_id:$cid})<-[:HAS_CHUNK]-(a:InformationArtifact) RETURN a.artifact_id AS id''',pid=card['package_id'],cid=chunk).single()
        assert row and row['id']==aid
        assert session.run('MATCH (:Move {move_id:$mid})-[:CITES_PASSAGE]->(:ArtifactChunk {chunk_id:$cid}) RETURN count(*) AS n',mid=card['moves'][0]['move_id'],cid=chunk).single()['n']==1
        assert session.run('MATCH (:InformationArtifact {artifact_id:$new})-[:SUPERSEDES]->(:InformationArtifact {artifact_id:$old}) RETURN count(*) AS n',new=revision['material']['artifact_id'],old=aid).single()['n']==1
    print('SHARED MATERIALS PASSED: PDF/DOCX/PPTX + scanned OCR, source integrity, deduplication, search, game isolation, citations, revisions, failed/retry states, immutability, and Neo4j evidence paths')

if __name__=='__main__': main()
