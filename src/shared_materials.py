"""Persistent shared sources, full-text retrieval and precise passage citations."""
import base64
import hashlib
import os
from pathlib import Path
import subprocess
from uuid import UUID, uuid4
import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb
from material_extraction import MIME, MAX_BYTES, validate_container, isolated_extract


def connect():
    return psycopg.connect(os.environ['WARGAME_PG_DSN'],row_factory=dict_row)


def as_uuid(value):
    try: return str(UUID(str(value)))
    except (ValueError,TypeError,AttributeError) as exc: raise ValueError('A valid record ID is required.') from exc


def locator_label(loc):
    if not loc: return 'Passage'
    kind=loc.get('kind')
    if kind=='page': label=f"Page {loc['page']}"
    elif kind in {'slide','slide_notes'}: label=f"Slide {loc['slide']}"+(' notes' if kind=='slide_notes' else f" · shape {loc.get('shape','')}")
    elif kind=='table_row': label=f"Table {loc['table']} · row {loc['row']}"
    else: label=f"{kind or 'paragraph'} {loc.get('paragraph','')}"+(f" · section {loc['section']}" if 'section' in loc else '')
    return label+f" · chars {loc.get('char_start',0)}–{loc.get('char_end',0)}"


def upload_material(payload):
    if not isinstance(payload,dict): raise ValueError('Expected an upload object.')
    game=as_uuid(payload.get('game_id'))
    filename=payload.get('filename')
    title=payload.get('title') or filename
    if not isinstance(filename,str) or not filename.strip() or len(filename)>255 or '/' in filename or '\\' in filename:
        raise ValueError('Use a filename of at most 255 characters without directory components.')
    if not isinstance(title,str) or not title.strip() or len(title)>300:
        raise ValueError('Title must contain 1–300 characters.')
    encoded=payload.get('content_base64')
    if not isinstance(encoded,str) or len(encoded)>((MAX_BYTES+2)//3)*4:
        raise ValueError('Document exceeds the 20 MB limit.')
    try: data=base64.b64decode(encoded,validate=True)
    except ValueError as exc: raise ValueError('Invalid base64 file content.') from exc
    ext=validate_container(data,filename)
    digest=hashlib.sha256(data).hexdigest()
    artifact=str(uuid4())
    with connect() as pg:
        pg.execute('SELECT pg_advisory_xact_lock(719731201)')
        if not pg.execute('SELECT 1 FROM wargame_game WHERE game_id=%s',(game,)).fetchone(): raise ValueError('Select an existing game.')
        existing=pg.execute('SELECT artifact_id FROM information_artifact WHERE game_id=%s AND source_sha256=%s',(game,digest)).fetchone()
        if existing: return material_detail(existing['artifact_id'])
        family,revision=artifact,1
        if payload.get('prior_artifact_id'):
            prior=pg.execute('SELECT source_family_id FROM information_artifact WHERE artifact_id=%s AND game_id=%s AND source_family_id IS NOT NULL',(as_uuid(payload['prior_artifact_id']),game)).fetchone()
            if not prior: raise ValueError('Prior source must be an uploaded material in the same game.')
            family=prior['source_family_id']
            revision=pg.execute('SELECT max(source_revision)+1 AS n FROM information_artifact WHERE game_id=%s AND source_family_id=%s',(game,family)).fetchone()['n']
        pg.execute('''INSERT INTO information_artifact(artifact_id,game_id,artifact_type,title,visibility,source_filename,source_mime_type,source_sha256,source_family_id,source_revision,processing_status,content_uri)
          VALUES (%s,%s,'other',%s,'shared',%s,%s,%s,%s,%s,'processing',%s)''',(artifact,game,title.strip(),filename,MIME[ext],digest,family,revision,'/api/materials/'+artifact+'/original'))
        pg.execute('INSERT INTO document_source(artifact_id,original_bytes) VALUES (%s,%s)',(artifact,data))
    return process_material(artifact)


def process_material(artifact):
    artifact=as_uuid(artifact)
    with connect() as pg:
        pg.execute('SELECT pg_advisory_xact_lock(719731201)')
        row=pg.execute('SELECT a.*,s.original_bytes FROM information_artifact a JOIN document_source s USING(artifact_id) WHERE artifact_id=%s FOR UPDATE OF a',(artifact,)).fetchone()
        if not row: raise ValueError('Material not found.')
        if row['processing_status']=='ready': return material_detail(artifact)
        pg.execute("UPDATE information_artifact SET processing_status='processing',processing_error=NULL WHERE artifact_id=%s",(artifact,))
    try:
        chunks=isolated_extract(bytes(row['original_bytes']),row['source_filename'])
        with connect() as pg:
            pg.execute('SELECT pg_advisory_xact_lock(719731201)')
            # A second retry may have completed while this parser was running.
            current=pg.execute('SELECT processing_status FROM information_artifact WHERE artifact_id=%s FOR UPDATE',(artifact,)).fetchone()
            if current['processing_status']!='ready':
                for ordinal, chunk in enumerate(chunks, 1):
                    pg.execute('INSERT INTO artifact_chunk(artifact_id,source_version,page,offset_start,offset_end,text_excerpt,source_locator,validity,visibility) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s)',(artifact,str(row['source_revision']),chunk['locator'].get('page'),chunk['locator']['char_start'],chunk['locator']['char_end'],chunk['text'],Jsonb({**chunk['locator'],'method':chunk['method'],'ordinal':ordinal}),'extracted; verify against original','shared'))
                pg.execute("UPDATE information_artifact SET processing_status='ready',processing_error=NULL,extraction_method=%s WHERE artifact_id=%s",(', '.join(sorted({c['method'] for c in chunks})),artifact))
    except (ValueError,subprocess.TimeoutExpired,psycopg.Error) as exc:
        with connect() as pg:
            pg.execute("UPDATE information_artifact SET processing_status='failed',processing_error=%s WHERE artifact_id=%s AND processing_status<>'ready'",(str(exc)[:1500],artifact))
    return material_detail(artifact)


def list_materials(game):
    with connect() as pg:
        return pg.execute('''SELECT a.artifact_id,a.title,a.source_filename,a.source_revision,a.source_family_id,a.processing_status,a.processing_error,a.extraction_method,a.created_at,
          (SELECT count(*) FROM artifact_chunk c WHERE c.artifact_id=a.artifact_id) AS passages,
          NOT EXISTS(SELECT 1 FROM information_artifact n WHERE n.game_id=a.game_id AND n.source_family_id=a.source_family_id AND n.source_revision>a.source_revision) AS latest
          FROM information_artifact a JOIN document_source s USING(artifact_id) WHERE a.game_id=%s ORDER BY a.created_at DESC LIMIT 500''',(as_uuid(game),)).fetchall()


def material_detail(artifact):
    with connect() as pg:
        row=pg.execute('SELECT a.* FROM information_artifact a JOIN document_source s USING(artifact_id) WHERE artifact_id=%s',(as_uuid(artifact),)).fetchone()
        if not row: raise ValueError('Material not found.')
        chunks=pg.execute('SELECT chunk_id,text_excerpt,source_locator FROM artifact_chunk WHERE artifact_id=%s',(artifact,)).fetchall()
        # UUID order is not reading order; sort by the explicit ordinal stored by the worker.
        chunks.sort(key=lambda c:c['source_locator'].get('ordinal',0))
        for c in chunks: c['citation']=locator_label(c['source_locator'])
        return {'material':row,'chunks':chunks}


def original_material(artifact):
    with connect() as pg:
        row=pg.execute('SELECT a.source_filename,a.source_mime_type,s.original_bytes FROM information_artifact a JOIN document_source s USING(artifact_id) WHERE artifact_id=%s',(as_uuid(artifact),)).fetchone()
        if not row: raise ValueError('Original file not found.')
        return row


def search_materials(game,query,include_history=False):
    if not isinstance(query,str) or not query.strip() or len(query)>500: raise ValueError('Enter a search of 1–500 characters.')
    with connect() as pg:
        rows=pg.execute('''WITH q AS (SELECT websearch_to_tsquery('english',%s) AS terms)
          SELECT c.chunk_id,c.artifact_id,c.text_excerpt,c.source_locator,a.title,a.source_revision,
          ts_rank_cd(to_tsvector('english',coalesce(c.text_excerpt,'')),q.terms) AS score
          FROM artifact_chunk c JOIN information_artifact a USING(artifact_id) CROSS JOIN q
          WHERE a.game_id=%s AND a.processing_status='ready'
          AND (%s OR NOT EXISTS(SELECT 1 FROM information_artifact n WHERE n.game_id=a.game_id AND n.source_family_id=a.source_family_id AND n.source_revision>a.source_revision AND n.processing_status='ready'))
          AND to_tsvector('english',coalesce(c.text_excerpt,'')) @@ q.terms
          ORDER BY score DESC,a.created_at DESC,c.chunk_id LIMIT 50''',(query.strip(),as_uuid(game),bool(include_history))).fetchall()
        for row in rows: row['citation']=locator_label(row['source_locator'])
        return {'results':rows,'query':query,'message':'Matching source passages; these are retrieved excerpts, not AI-generated answers.'}


def passage_detail(chunk):
    with connect() as pg:
        row=pg.execute('''SELECT c.*,a.title,a.game_id,a.source_revision FROM artifact_chunk c JOIN information_artifact a USING(artifact_id) WHERE c.chunk_id=%s AND a.processing_status='ready' ''',(as_uuid(chunk),)).fetchone()
        if not row: raise ValueError('Ready passage not found.')
        row['citation']=locator_label(row['source_locator'])
        return row
