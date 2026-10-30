"""Local, single-process proof-of-concept UI. Database rules remain authoritative."""
import json
import os
import sys
from pathlib import Path
from uuid import uuid4
from wsgiref.simple_server import make_server
from urllib.parse import urlsplit, parse_qs, quote

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src' if (ROOT / 'src').is_dir() else ROOT
sys.path[:0] = [str(SOURCE), str(ROOT / 'docker')]
import psycopg
from psycopg import sql
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb
from validate_turn_card import validate_turn_card
from manage import configure
from etl_postgres_to_neo4j import sync_postgres_to_neo4j
from shared_materials import (upload_material, process_material, list_materials, material_detail,
    original_material, search_materials, passage_detail, as_uuid)
SCHEMA = json.loads((SOURCE / 'Wargame_TurnSubmissionPackage.schema.json').read_text())
LIMIT = 2 * 1024 * 1024
UPLOAD_LIMIT = 29 * 1024 * 1024


def uid():
    return str(uuid4())


def connection():
    return psycopg.connect(os.environ['WARGAME_PG_DSN'], row_factory=dict_row)


def insert(pg, table, row):
    pg.execute(sql.SQL('INSERT INTO {} ({}) VALUES ({})').format(
        sql.Identifier(table), sql.SQL(',').join(map(sql.Identifier, row)),
        sql.SQL(',').join(sql.Placeholder() for _ in row)), list(row.values()))


def check_document(doc):
    errors = validate_turn_card(doc, SCHEMA)
    if errors:
        raise ValueError('\n'.join(errors))
    if doc['receipt_status'] not in {'draft', 'submitted'}:
        raise ValueError('Import supports new draft or submitted cards only; processing history cannot be imported.')
    if any(m['status'] not in {'draft', 'submitted'} for m in doc['moves']):
        raise ValueError('Imported moves must be draft or submitted.')
    return doc


def reference(pg, table, key, value, game_id, extra='', args=()):
    if value is None:
        return
    row = pg.execute(sql.SQL('SELECT 1 FROM {} WHERE {}=%s AND ' + extra).format(
        sql.Identifier(table), sql.Identifier(key)), (value, *args)).fetchone()
    if not row:
        raise ValueError(f'{table}.{key}: {value} is missing or belongs to another game/turn/team')


def import_card(doc, dry_run=False):
    check_document(doc)
    with connection() as pg:
        pg.execute('SELECT pg_advisory_xact_lock(719731201)')
        context = pg.execute('SELECT t.game_id,t.status,p.team_id FROM turn t JOIN player_team p ON p.game_id=t.game_id WHERE t.turn_id=%s AND p.team_id=%s FOR UPDATE OF t,p', (doc['turn_id'], doc['submitting_team_id'])).fetchone()
        if not context or context['status'] != 'open':
            raise ValueError('Select an open turn and a team belonging to the same game.')
        gid = context['game_id']
        if pg.execute('SELECT 1 FROM turn_submission_package WHERE package_id=%s', (doc['package_id'],)).fetchone():
            raise ValueError('This package ID already exists. Import creates new cards; it never overwrites existing cards.')
        def ref(table, key, value, extra='game_id=%s', args=None):
            reference(pg, table, key, value, gid, extra, (gid,) if args is None else args)
        local_artifacts = {a['artifact_id'] for a in doc.get('ms_packages', [])}
        for artifact_id in doc.get('cited_artifact_ids', []):
            if artifact_id not in local_artifacts:
                ref('information_artifact', 'artifact_id', artifact_id)
        for m in doc['moves']:
            ref('decision', 'decision_id', m.get('decision_id'), 'team_id=%s AND turn_id=%s', (doc['submitting_team_id'], doc['turn_id']))
            for artifact_id in m.get('cited_artifact_ids', []):
                if artifact_id not in local_artifacts:
                    ref('information_artifact', 'artifact_id', artifact_id)
            for rfi_id in m.get('rfi_ids', []):
                ref('rfi', 'rfi_id', rfi_id, 'requesting_team_id=%s AND turn_id=%s', (doc['submitting_team_id'], doc['turn_id']))
            for a in m['actions']:
                ref('actor', 'actor_id', a.get('actor_id'))
                for i in a.get('instruments_of_power', []):
                    ref('actor', 'actor_id', i.get('responsible_actor_id'))
        insert(pg, 'turn_submission_package', {**{k: doc[k] for k in ('package_id','turn_id','submitting_team_id','revision','schema_version','notes') if k in doc}, 'receipt_status':'draft'})
        for artifact in doc.get('ms_packages', []):
            insert(pg, 'information_artifact', {'artifact_id': artifact['artifact_id'], 'game_id':gid, 'artifact_type':'ms_result', 'model_version':artifact['model_version'], 'ms_inputs':Jsonb(artifact.get('inputs', {})), 'ms_assumptions':artifact.get('assumptions'), 'ms_outputs':Jsonb(artifact.get('outputs'))})
            insert(pg, 'package_artifact', {'package_id':doc['package_id'], 'artifact_id':artifact['artifact_id']})
        for artifact_id in set(doc.get('cited_artifact_ids', [])) - {a['artifact_id'] for a in doc.get('ms_packages', [])}:
            insert(pg, 'package_artifact', {'package_id':doc['package_id'], 'artifact_id':artifact_id})
        def children(parent, fk, value):
            for field, table in [('dependencies','dependency'),('risks','risk'),('instruments_of_power','instrument_of_power'),('desired_effects','desired_effect')]:
                for child in parent.get(field, []):
                    insert(pg, table, {**child, fk:value})
        for m in doc['moves']:
            insert(pg, 'move', {**{k:m[k] for k in ('move_id','version','decision_id') if k in m}, 'package_id':doc['package_id'], 'turn_id':doc['turn_id'], 'team_id':doc['submitting_team_id'], 'status':'draft'})
            children(m, 'move_id', m['move_id'])
            for a in m['actions']:
                insert(pg, 'action', {**{k:v for k,v in a.items() if k not in {'dependencies','risks','desired_effects','instruments_of_power'}}, 'move_id':m['move_id']})
                children(a, 'action_id', a['action_id'])
            for artifact_id in m.get('cited_artifact_ids', []):
                insert(pg, 'move_artifact', {'move_id':m['move_id'], 'artifact_id':artifact_id})
            for rfi_id in m.get('rfi_ids', []):
                insert(pg, 'move_rfi', {'move_id':m['move_id'], 'rfi_id':rfi_id})
        def citations(parent, move_id=None):
            for chunk_id in parent.get('cited_chunk_ids', []):
                # SQL trigger enforces same game, ready source and move/package scope.
                insert(pg, 'submission_citation', {'package_id':doc['package_id'], 'move_id':move_id, 'chunk_id':chunk_id})
                artifact_id=pg.execute('SELECT artifact_id FROM artifact_chunk WHERE chunk_id=%s',(chunk_id,)).fetchone()['artifact_id']
                pg.execute('INSERT INTO package_artifact(package_id,artifact_id) VALUES (%s,%s) ON CONFLICT DO NOTHING',(doc['package_id'],artifact_id))
                if move_id:
                    pg.execute('INSERT INTO move_artifact(move_id,artifact_id) VALUES (%s,%s) ON CONFLICT DO NOTHING',(move_id,artifact_id))
        citations(doc)
        for m in doc['moves']: citations(m,m['move_id'])
        # Store the complete original exchange document, including its timestamps.
        source_id = uid()
        insert(pg, 'information_artifact', {'artifact_id':source_id, 'game_id':gid, 'artifact_type':'other', 'title':'Imported turn card ' + doc['package_id']})
        insert(pg, 'artifact_chunk', {'artifact_id':source_id, 'text_excerpt':json.dumps(doc), 'validity':'original import'})
        insert(pg, 'package_artifact', {'package_id':doc['package_id'], 'artifact_id':source_id})
        for m in doc['moves']:
            if m['status'] == 'submitted':
                pg.execute("UPDATE move SET status='submitted' WHERE move_id=%s", (m['move_id'],))
        if doc['receipt_status'] == 'submitted':
            pg.execute("UPDATE turn_submission_package SET receipt_status='submitted' WHERE package_id=%s", (doc['package_id'],))
        if dry_run:
            pg.rollback()
    return {'package_id':doc['package_id'], 'message':'Validation passed, including references and database rules. No records saved.' if dry_run else 'Saved to PostgreSQL. Refresh the graph to project this card into Neo4j.'}


def new_example():
    game, team, turn, actor = [uid() for _ in range(4)]
    with connection() as pg:
        pg.execute('SELECT pg_advisory_xact_lock(719731201)')
        insert(pg, 'wargame_game', {'game_id':game, 'name':'Turn card workshop'})
        insert(pg, 'player_team', {'team_id':team,'game_id':game,'name':'Blue team'})
        insert(pg, 'actor', {'actor_id':actor,'game_id':game,'name':'Response unit','actor_type':'organization'})
        insert(pg, 'turn', {'turn_id':turn,'game_id':game,'turn_number':1})
        pg.execute("UPDATE turn SET status='open', opened_at=now() WHERE turn_id=%s", (turn,))
    return {'package_id':uid(),'turn_id':turn,'submitting_team_id':team,'revision':1,'receipt_status':'draft','notes':'Synthetic proof of concept','moves':[{'move_id':uid(),'version':1,'status':'draft','actions':[{'action_id':uid(),'action_class':'Action','actor_id':actor,'statement':'Deliver supplies to the community center','timing':'Day 1','location':'Community center','risks':[{'statement':'Road access may be interrupted','mitigation':'Prepare an alternate route'}],'desired_effects':[{'effect':'Community receives essential supplies','horizon':'This turn'}]}]}]}


def overview():
    with connection() as pg:
        contexts=pg.execute('SELECT g.game_id,g.name AS game,t.turn_id,t.turn_number,t.status,p.team_id,p.name AS team FROM wargame_game g JOIN turn t USING(game_id) JOIN player_team p USING(game_id) ORDER BY g.created_at DESC,t.turn_number LIMIT 200').fetchall()
        packages=pg.execute('SELECT s.package_id,s.receipt_status,s.revision,s.submitted_at,g.name AS game,t.turn_number,p.name AS team,(SELECT count(*) FROM move m WHERE m.package_id=s.package_id) AS moves FROM turn_submission_package s JOIN turn t USING(turn_id) JOIN wargame_game g USING(game_id) JOIN player_team p ON p.team_id=s.submitting_team_id ORDER BY s.created_at DESC LIMIT 100').fetchall()
        games=pg.execute('SELECT game_id,name FROM wargame_game ORDER BY created_at DESC LIMIT 500').fetchall()
    return {'contexts':contexts,'packages':packages,'games':games}


def evidence(package):
    with connection() as pg:
        rows=pg.execute('''SELECT sc.package_id,sc.move_id,c.chunk_id,c.artifact_id,c.text_excerpt,c.source_locator,a.title,a.source_revision
          FROM submission_citation sc JOIN artifact_chunk c USING(chunk_id) JOIN information_artifact a USING(artifact_id)
          WHERE sc.package_id=%s ORDER BY sc.created_at''',(as_uuid(package),)).fetchall()
    from shared_materials import locator_label
    for row in rows: row['citation']=locator_label(row['source_locator'])
    return {'citations':rows}



def application(environ, start_response):
    status = '200 OK'
    headers = [('Cache-Control','no-store'),('X-Content-Type-Options','nosniff'),('Content-Security-Policy',"default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")]
    try:
        path, method = environ['PATH_INFO'], environ['REQUEST_METHOD']
        if method == 'GET' and path in {'/','/app.js'}:
            file = Path(__file__).parent / ('index.html' if path == '/' else 'app.js')
            body = file.read_bytes()
            headers.append(('Content-Type','text/html; charset=utf-8' if path == '/' else 'text/javascript; charset=utf-8'))
        else:
            if method == 'GET' and path == '/api/health':
                with connection() as pg: pg.execute('SELECT 1')
                result={'ready':True}
            elif method == 'GET' and path == '/api/overview': result=overview()
            elif method == 'GET' and path.startswith('/api/materials/') and path.endswith('/original'):
                source=original_material(path.split('/')[3])
                body=bytes(source['original_bytes'])
                headers.extend([('Content-Type',source['source_mime_type']),('Content-Disposition',"attachment; filename*=UTF-8''"+quote(source['source_filename'],safe='')),('Content-Length',str(len(body)))])
                start_response(status,headers)
                return [body]
            elif method == 'GET':
                query=parse_qs(environ.get('QUERY_STRING',''))
                if path=='/api/materials': result={'materials':list_materials(query.get('game_id',[''])[0])}
                elif path=='/api/search': result=search_materials(query.get('game_id',[''])[0],query.get('q',[''])[0],query.get('history',['false'])[0]=='true')
                elif path=='/api/evidence': result=evidence(query.get('package_id',[''])[0])
                elif path.startswith('/api/materials/'): result=material_detail(path.split('/')[3])
                elif path.startswith('/api/passages/'): result=passage_detail(path.split('/')[3])
                else:
                    status='404 Not Found'
                    result={'error':'Not found'}
            elif method == 'POST':
                # Block cross-site form posts and browser requests from another origin.
                origin=environ.get('HTTP_ORIGIN')
                if origin and urlsplit(origin).netloc != environ.get('HTTP_HOST'):
                    raise ValueError('Cross-origin writes are forbidden.')
                if environ.get('CONTENT_TYPE','').split(';')[0] != 'application/json':
                    raise ValueError('Use application/json.')
                length=int(environ.get('CONTENT_LENGTH') or 0)
                limit=UPLOAD_LIMIT if path=='/api/materials/upload' else LIMIT
                if not 0 < length <= limit: raise ValueError('Request exceeds the allowed size.')
                data=json.loads(environ['wsgi.input'].read(length))
                if path == '/api/materials/upload': result=upload_material(data)
                elif path == '/api/materials/retry': result=process_material(data.get('artifact_id') if isinstance(data,dict) else None)
                elif path == '/api/example': result=new_example()
                elif path == '/api/validate': result=import_card(data, dry_run=True)
                elif path == '/api/import': result=import_card(data)
                elif path == '/api/sync':
                    sync_postgres_to_neo4j()
                    result={'message':'Neo4j graph refreshed successfully.'}
                else: raise ValueError('Unknown endpoint.')
            else:
                status='404 Not Found'
                result={'error':'Not found'}
            body=json.dumps(result, default=str).encode()
            headers.append(('Content-Type','application/json; charset=utf-8'))
    except (ValueError, psycopg.Error) as exc:
        status='400 Bad Request'
        body=json.dumps({'error':str(exc).split('\nCONTEXT:')[0]}).encode()
        headers.append(('Content-Type','application/json; charset=utf-8'))
    except Exception:
        import logging
        logging.exception('Interface request failed')
        status='503 Service Unavailable'
        body=json.dumps({'error':'Service unavailable. Check web container logs. Saved PostgreSQL cards remain available; graph refresh can be retried.'}).encode()
        headers.append(('Content-Type','application/json; charset=utf-8'))
    headers.append(('Content-Length',str(len(body))))
    start_response(status, headers)
    return [body]


if __name__ == '__main__':
    configure()
    print('Wargame interface listening on port 8080', flush=True)
    with make_server('0.0.0.0',8080,application) as server:
        server.serve_forever()
