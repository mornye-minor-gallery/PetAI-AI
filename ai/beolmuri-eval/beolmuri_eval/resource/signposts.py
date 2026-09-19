"""Verified os-signpost-interval shape; match both endpoints and the owned PID."""
import xml.etree.ElementTree as ET


def window_from_trace(data, *, run_id, pid):
    if b'<!DOCTYPE' in data or b'<!ENTITY' in data: raise ValueError('unsupported XML declaration')
    root=ET.fromstring(data)
    ids={}
    for item in root.iter():
        if 'id' in item.attrib:
            if item.get('id') in ids: raise ValueError('duplicate signpost id')
            ids[item.get('id')]=item
    def resolve(item):
        seen=set()
        while 'ref' in item.attrib:
            key=item.get('ref')
            if key in seen or key not in ids: raise ValueError('invalid signpost reference')
            seen.add(key)
            target=ids[key]
            if target.tag!=item.tag: raise ValueError('signpost reference type mismatch')
            item=target
        return item
    def text(item):
        item=resolve(item)
        if item.tag=='os-log-metadata': return ''.join(text(c) for c in item)
        return item.text or ''
    found=[]
    for node in root.findall('node'):
        schema=node.find('schema')
        if schema is None or schema.get('name')!='os-signpost-interval': continue
        columns=[c.findtext('mnemonic') for c in schema.findall('col')]
        for row in node.findall('row'):
            if len(row)!=len(columns): raise ValueError('invalid signpost row')
            cells=dict(zip(columns,row))
            if text(cells['name'])!='PowerWindow' or text(cells['subsystem'])!='org.petai.resourcebench': continue
            if text(cells['start-message']).lower()!=run_id.lower() or text(cells['end-message']).lower()!=run_id.lower(): continue
            for key in ('process','end-process'):
                process=resolve(cells[key]); actual=process.find('pid')
                if actual is None or int(text(actual))!=pid: raise ValueError('signpost process mismatch')
            start,duration=int(text(cells['start'])),int(text(cells['duration']))
            if start<0 or duration<=0: raise ValueError('incomplete power signpost')
            found.append((start,start+duration))
    if len(found)!=1: raise ValueError('expected one complete owned PowerWindow interval')
    return found[0]
