from copy import deepcopy
from io import BytesIO
import json
from pathlib import Path
import shutil
import sys
import zipfile
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from material_extraction import extract,validate_container,chunks_from_units,isolated_extract
from shared_materials import locator_label,as_uuid
from material_fixtures import docx_bytes,pptx_bytes,pdf_bytes,scanned_pdf_bytes,TEXT
from test_validation import CARD,errors

@pytest.mark.parametrize('filename,maker,method', [('sample.pdf',pdf_bytes,'pdf-text'),('sample.docx',docx_bytes,'docx-text'),('sample.pptx',pptx_bytes,'pptx-text')])
def test_extract_formats(filename,maker,method):
    chunks=extract(maker(),filename)
    assert any(TEXT in c['text'] for c in chunks)
    assert any(c['method']==method for c in chunks)
    assert all(c['locator']['char_end']>c['locator']['char_start'] for c in chunks)
    assert all(locator_label(c['locator']) for c in chunks)

def test_docx_table_locator():
    chunks=extract(docx_bytes(),'sample.docx')
    assert any(c['locator'].get('table')==1 and c['locator'].get('row')==2 and 'Water | 50' in c['text'] for c in chunks)

def test_slide_table_notes_locators():
    chunks=extract(pptx_bytes(),'sample.pptx')
    assert any(c['method']=='pptx-table' and c['locator']['slide']==1 for c in chunks)
    assert any(c['method']=='pptx-notes' and 'depot access' in c['text'] for c in chunks)

def test_process_isolation_round_trip():
    assert any(TEXT in c['text'] for c in isolated_extract(docx_bytes(),'sample.docx'))

@pytest.mark.skipif(not shutil.which('pdftoppm') or not shutil.which('tesseract'),reason='Native OCR tools are tested in Docker')
def test_scanned_pdf_ocr():
    chunks=isolated_extract(scanned_pdf_bytes(),'scanned.pdf')
    assert any(c['method']=='pdf-ocr-eng' and 'depot' in c['text'].lower() for c in chunks)

@pytest.mark.parametrize('filename,data',[('x.doc',b'x'),('x.ppt',b'x'),('x.pdf',b'not a pdf'),('x.docx',b'invalid zip')])
def test_invalid_containers(filename,data):
    with pytest.raises(ValueError): validate_container(data,filename)

def test_office_type_mismatch():
    with pytest.raises(ValueError): validate_container(docx_bytes(),'wrong.pptx')

def test_expanded_zip_limit():
    out=BytesIO()
    with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED) as z:
        z.writestr('word/document.xml',b'x'*(81*1024*1024))
    with pytest.raises(ValueError,match='expanded-size'): validate_container(out.getvalue(),'bomb.docx')

def test_chunks_keep_source_offsets():
    chunks=chunks_from_units([({'kind':'paragraph','paragraph':4},'x'*4000,'docx-text')])
    assert [c['locator']['char_start'] for c in chunks]==[0,1800,3600]
    assert ''.join(c['text'] for c in chunks)=='x'*4000

def test_empty_text_explicit_failure():
    with pytest.raises(ValueError,match='No readable text'): chunks_from_units([])

def test_passage_ids_allowed_in_json_contract():
    doc=deepcopy(CARD);doc['cited_chunk_ids']=[CARD['package_id']];doc['moves'][0]['cited_chunk_ids']=[CARD['turn_id']]
    assert not errors(doc)
    doc['moves'][0]['cited_chunk_ids'].append(CARD['turn_id']);assert errors(doc)

def test_invalid_uuid_clear_error():
    with pytest.raises(ValueError,match='valid record ID'): as_uuid(None)

def test_initial_schema_and_migration_are_identical():
    root=Path(__file__).resolve().parents[1]
    assert (root/'migrations/shared_materials.sql').read_text() in (root/'Wargame_Schema_PostgreSQL.sql').read_text()
