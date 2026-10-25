#!/usr/bin/env python3
"""Real Notes integration regressions. Uses only uniquely named disposable data.
Build `make note-state`, then run `python3 tests/issues.py [cloud|images]`.
Cloud tests require Notes.app running and a working iCloud account.
"""
import base64
import json
import pathlib
import struct
import subprocess
import sys
import tempfile
import time
import uuid
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = ROOT / 'notekit'
STATE = ROOT / 'note-state'

def command(*args, text=None, ok=True):
    p = subprocess.run([str(BIN), *map(str, args)], input=text, text=True, capture_output=True)
    if ok and p.returncode:
        raise AssertionError(f'{args}: {p.stderr}')
    return (p.stdout if args[0] == 'read-markdown' else json.loads(p.stdout)) if ok else p

def state(note):
    p = subprocess.run([str(STATE), note], capture_output=True, text=True, check=True)
    return json.loads(p.stdout)

def wait_cloud(note, version=None):
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        s = state(note)
        target = s['localVersion'] if version is None else version
        if s['inCloud'] and s['syncedVersion'] >= target and all(c['inCloud'] and c['syncedVersion'] >= c['localVersion'] for a in s['attachments'] for c in a['cloud']):
            return s
        time.sleep(1)
    raise AssertionError(f'iCloud did not acknowledge version {target}: {s["localVersion"]}/{s["syncedVersion"]}')

def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'images'
    folder = '__notekit_issue_tests_' + uuid.uuid4().hex
    command('create-folder', '--name', folder)
    notes = []
    folders = [folder]
    try:
        note = command('create', '--folder', folder, '--title', 'Attachment test', '--body', 'before\nafter')['id']
        notes.append(note)
        if mode == 'cloud':
            wait_cloud(note)
            before = state(note)
            command('append', '--id', note, '--text', 'cloud regression')
            after = state(note)
            assert after['localVersion'] > before['localVersion'], 'edit did not advance cloud version'
            wait_cloud(note, after['localVersion'])
            for verb in ('pin', 'unpin'):
                before = state(note)
                command(verb, '--id', note)
                after = state(note)
                assert after['localVersion'] > before['localVersion'], f'{verb} did not advance cloud version'
                assert after['pinned'] == (verb == 'pin')
                assert after['modified'] == before['modified'], f'{verb} changed modification date'
                wait_cloud(note, after['localVersion'])
            command('insert', '--id', note, '--text', 'inserted ', '--position', 0, '--body-offset')
            wait_cloud(note)
            assert 'inserted before' in state(note)['text']
            for diff in (False, True):
                markdown = command('read-markdown', '--id', note).replace('before', 'edited before')
                command('write-markdown', '--id', note, *(['--diff'] if diff else []), text=markdown)
                wait_cloud(note)
                assert 'edited before' in state(note)['text']
            target = folder + '_target'
            command('create-folder', '--name', target)
            folders.append(target)
            command('move', '--id', note, '--to', target)
            wait_cloud(note)
            assert command('get', '--id', note)['folder'] == target
            print('PASS: append, insert, Markdown replace/diff, pin, unpin, move acknowledged by iCloud')
            return
        # Small RGB PNG with valid CRCs, constructed without image dependencies.
        def chunk(kind, data):
            return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
        png = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 4, 4, 8, 2, 0, 0, 0))
               + chunk(b'IDAT', zlib.compress((b'\x00' + b'\xff\x00\x00' * 4) * 4)) + chunk(b'IEND', b''))
        with tempfile.TemporaryDirectory() as directory:
            image = pathlib.Path(directory) / 'summary image.png'
            image.write_bytes(png)
            result = command('insert-image', '--id', note, '--file', image, '--position', 0, '--body-offset')
            attachment = result['attachmentId']
            assert state(note)['attachments'][0]['preferredViewSize'] == 0, 'default must remain Large'
            s = state(note)
            a = next(x for x in s['attachments'] if x['id'] == attachment)
            assert a['position'] == result['position'] and a['length'] == 1
            assert base64.b64decode(a['data']) == png, 'imported media changed'
            # Preferences must persist across CLI processes and Markdown edits.
            for view, expected in (('small', 1), ('large', 0)):
                sized = command('insert-image', '--id', note, '--file', image, '--view', view)['attachmentId']
                def check_size():
                    item = next(a for a in state(note)['attachments'] if a['id'] == sized)
                    assert item['preferredViewSize'] == expected, (view, item)
                    assert base64.b64decode(item['data']) == png
                check_size()
                for diff in (True, False):
                    markdown = command('read-markdown', '--id', note).replace('before', 'edited before')
                    command('write-markdown', '--id', note, *(['--diff'] if diff else []), text=markdown)
                    check_size()
                wait_cloud(note)
                check_size()
                command('delete-attachment', '--id', note, '--attachment', sized)
            before_invalid = state(note)
            for arguments in (('--view', 'medium'), ('--view',), ('--view', '--body-offset')):
                failed = command('insert-image', '--id', note, '--file', image, *arguments, ok=False)
                assert failed.returncode and '--view' in failed.stderr, failed
                after_invalid = state(note)
                assert after_invalid['text'] == before_invalid['text']
                assert [(a['id'], a['preferredViewSize'], a['data']) for a in after_invalid['attachments']] == [(a['id'], a['preferredViewSize'], a['data']) for a in before_invalid['attachments']]
            # Read through the actual Notes app as well as the private framework.
            script = 'on run argv\ntell application "Notes" to get body of first note of folder (item 1 of argv)\nend run'
            html = subprocess.run(['/usr/bin/osascript', '-e', script, '--', folder], capture_output=True, text=True, check=True).stdout
            assert '<img' in html.lower() or '<object' in html.lower(), html
            md = command('read-markdown', '--id', note)
            assert f'notekit-attachment:{attachment}' in md, md
            for diff in (True, False):
                md = md.replace('before', 'updated before')
                command('write-markdown', '--id', note, *(['--diff'] if diff else []), text=md)
                s = state(note)
                a = next(x for x in s['attachments'] if x['id'] == attachment)
                assert a['length'] == 1 and base64.b64decode(a['data']) == png
                assert s['text'][a['position']] == '\ufffc'
                md = command('read-markdown', '--id', note)
            before = state(note)
            invalid = pathlib.Path(directory) / 'invalid.png'
            invalid.write_text('not an image')
            assert command('insert-image', '--id', note, '--file', invalid, ok=False).returncode
            assert state(note)['text'] == before['text']
            other = command('create', '--folder', folder, '--title', 'Other note', '--body', 'untouched')['id']
            notes.append(other)
            assert command('delete-attachment', '--id', other, '--attachment', attachment, ok=False).returncode
            assert command('write-markdown', '--id', other, text=md, ok=False).returncode
            assert 'untouched' in state(other)['text']
            duplicate_reference = md + '\n![image](notekit-attachment:' + attachment + ')'
            assert command('write-markdown', '--id', note, text=duplicate_reference, ok=False).returncode
            assert state(note)['text'] == before['text']
            for bad in ('-1', 'abc', '999999999999999999999999', '999999'):
                p = command('insert-image', '--id', note, '--file', image, '--position', bad, ok=False)
                assert p.returncode != 0, f'accepted invalid position {bad}'
                assert state(note)['text'] == before['text']
                assert len(state(note)['attachments']) == len(before['attachments'])
            wait_cloud(note)
            command('delete-attachment', '--id', note, '--attachment', attachment)
            s = state(note)
            assert not s['attachments'] and '\ufffc' not in s['text']
            assert command('delete-attachment', '--id', note, '--attachment', attachment, ok=False).returncode
            # Exercise JPEG and omitted-position append through the same import API.
            jpeg = pathlib.Path(directory) / 'summary.jpeg'
            subprocess.run(['/usr/bin/sips', '-s', 'format', 'jpeg', str(image), '--out', str(jpeg)], check=True, capture_output=True)
            old_length = len(s['text'].encode('utf-16-le')) // 2
            result = command('insert-image', '--id', note, '--file', jpeg)
            s = state(note)
            assert result['position'] == old_length
            a = next(x for x in s['attachments'] if x['id'] == result['attachmentId'])
            assert a['uti'] == 'public.jpeg'
            assert base64.b64decode(a['data']) == jpeg.read_bytes()
            jpeg_id = result['attachmentId']
            second = command('insert-image', '--id', note, '--file', image)['attachmentId']
            markdown = command('read-markdown', '--id', note)
            swapped = markdown.replace(jpeg_id, 'TEMPORARY_ID').replace(second, jpeg_id).replace('TEMPORARY_ID', second)
            command('write-markdown', '--id', note, '--diff', text=swapped)
            attachments = {a['id']: a for a in state(note)['attachments']}
            assert attachments[second]['position'] < attachments[jpeg_id]['position']
            assert base64.b64decode(attachments[second]['data']) == png
            assert base64.b64decode(attachments[jpeg_id]['data']) == jpeg.read_bytes()
            command('delete-attachment', '--id', note, '--attachment', jpeg_id)
            command('delete-attachment', '--id', note, '--attachment', second)
            wait_cloud(note)
            print('PASS: PNG/JPEG, Notes.app HTML, positions, Markdown diff/replace, invalid and cross-note input, deletion, iCloud')
    finally:
        for note in notes:
            command('delete', '--id', note, ok=False)
        for folder in reversed(folders):
            command('delete-folder', '--name', folder, ok=False)

if __name__ == '__main__':
    main()
