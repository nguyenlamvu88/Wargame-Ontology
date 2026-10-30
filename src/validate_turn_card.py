#!/usr/bin/env python3
"""Validate a turn card and, optionally, its transition from a prior card."""
import argparse
from copy import deepcopy
from datetime import datetime
import json
from pathlib import Path
import sys
from jsonschema import Draft202012Validator, FormatChecker
from jsonschema.exceptions import SchemaError

ROOT = Path(__file__).resolve().parent
RULES = json.loads((ROOT / 'workflow_rules.json').read_text())
COMPATIBLE = {
 'draft': {'draft','submitted'}, 'returned': {'draft','submitted'},
 'submitted': {'submitted','under_adjudication','resolved'},
 'locked': {'submitted','under_adjudication','resolved'},
 'accepted': {'submitted','under_adjudication','resolved'},
}

def validate_turn_card(doc, schema, prior_doc=None):
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    errors = [f'[SCHEMA] {e.json_path}: {e.message}' for e in
              sorted(validator.iter_errors(doc),key=lambda e:e.json_path)]
    # Domain checks may only traverse a structurally valid document.
    if errors:
        return errors
    if prior_doc is not None:
        prior_errors = list(validator.iter_errors(prior_doc))
        if prior_errors:
            return ['[PRIOR] Prior document does not conform to this schema; migrate it before comparison.']
    def transition(entity, old, new, path):
        if old != new and new not in RULES[entity].get(old, []):
            errors.append(f'[TRANSITION] {path}: {old} -> {new} is forbidden')
    seen_moves, seen_actions = set(), set()
    for move in doc['moves']:
        mid = move['move_id']
        if mid in seen_moves:
            errors.append(f'[UNIQUENESS] duplicate move_id {mid}')
        seen_moves.add(mid)
        if move['status'] not in COMPATIBLE[doc['receipt_status']]:
            errors.append(f'[STATE] incompatible move status for package: {mid}')
        for action in move['actions']:
            aid = action['action_id']
            if aid in seen_actions:
                errors.append(f'[UNIQUENESS] duplicate action_id {aid}')
            seen_actions.add(aid)
    if prior_doc is not None:
        if doc['package_id'] != prior_doc['package_id']:
            errors.append('[IDENTITY] Cannot compare different packages')
        old = prior_doc['receipt_status']
        transition('turn_submission_package',old,doc['receipt_status'],'receipt_status')
        old_moves = {m['move_id']:m for m in prior_doc['moves']}
        for move in doc['moves']:
            if move['move_id'] in old_moves:
                before=old_moves[move['move_id']]
                transition('move',before['status'],move['status'],f"move {move['move_id']}")
                if before['status']=='submitted' and move['status']=='draft' and doc['receipt_status']!='returned':
                    errors.append('[STATE] Move reset requires returned package')
        if old in {'locked','accepted'}:
            def content(d):
                d=deepcopy(d)
                d.pop('receipt_status',None)
                # Map by ID: array order alone has no relational content meaning.
                d['moves']={m['move_id']:{k:v for k,v in m.items() if k!='status'} for m in d['moves']}
                return d
            if content(doc)!=content(prior_doc):
                errors.append('[IMMUTABILITY] Locked package content changed; only move processing status may change')
        if old=='returned' and doc['receipt_status']=='submitted':
            if doc['revision']<=prior_doc['revision']:
                errors.append('[REVISION] Resubmission must increment revision')
            if prior_doc.get('submitted_at') and datetime.fromisoformat(doc['submitted_at'].replace('Z','+00:00')) <= datetime.fromisoformat(prior_doc['submitted_at'].replace('Z','+00:00')):
                errors.append('[TIMESTAMP] Resubmission requires a newer submitted_at')
    return errors

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('json_file')
    p.add_argument('--schema',default=str(ROOT/'Wargame_TurnSubmissionPackage.schema.json'))
    p.add_argument('--prior')
    args=p.parse_args()
    try:
        schema=json.loads(Path(args.schema).read_text())
        Draft202012Validator.check_schema(schema)
        doc=json.loads(Path(args.json_file).read_text())
        prior=json.loads(Path(args.prior).read_text()) if args.prior else None
        errors=validate_turn_card(doc,schema,prior)
    except (OSError,ValueError,SchemaError) as e:
        print(f'INPUT ERROR: {e}',file=sys.stderr)
        return 2
    if errors:
        print('\n'.join(errors))
        return 1
    print('VALIDATION PASSED')
    return 0

if __name__=='__main__':
    sys.exit(main())
