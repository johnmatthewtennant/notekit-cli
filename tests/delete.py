#!/usr/bin/env python3
"""Issue #63: real, recoverable deletion and cloud acknowledgement.

Requires a Mac with Notes Automation permission and iCloud. Creates one uniquely
named note in an EXISTING folder, never a test folder. Use --folder to choose it.
Run against a version known to hard-delete rows only with --allow-hard-delete:
that baseline deliberately reproduces the defect and may require cloud recovery.
"""
import argparse
import json
import pathlib
import subprocess
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]


def call(*args, check=True):
    p = subprocess.run([str(ROOT / 'notekit'), *args], text=True, capture_output=True, timeout=60)
    if check and p.returncode:
        raise AssertionError(f'{args}: {p.stderr}')
    return json.loads(p.stdout) if check else p


def observe(identifier):
    p = subprocess.run([str(ROOT / 'note-state'), identifier], text=True, capture_output=True, check=True, timeout=20)
    return json.loads(p.stdout)


def wait_for(identifier, predicate, description):
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        value = observe(identifier)
        if predicate(value):
            return value
        time.sleep(1)
    raise AssertionError(f'{description}: {value}')


def acknowledged(value):
    return value.get('exists') and value['inCloud'] and value['syncedVersion'] >= value['localVersion']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--folder', default='Notes')
    parser.add_argument('--allow-hard-delete', action='store_true')
    args = parser.parse_args()
    # The help entry identifies versions with recoverable deletion.
    help_text = subprocess.run([str(ROOT / 'notekit'), '--help'], text=True, capture_output=True, check=True).stderr
    if 'Recently Deleted' not in help_text and not args.allow_hard_delete:
        raise SystemExit('Refusing to run a known hard-delete baseline without --allow-hard-delete')
    title = '__notekit_delete_regression_' + uuid.uuid4().hex
    note = call('create', '--folder', args.folder, '--title', title, '--body', 'Recoverable deletion regression')['id']
    print(f'Fixture: {note} ({title})', flush=True)
    before = wait_for(note, acknowledged, 'initial note did not reach iCloud')
    print(f'Initial cloud version: {before["localVersion"]}/{before["syncedVersion"]}', flush=True)
    result = call('delete', '--id', note)
    assert result['id'] == note and result['deleted'] is True
    after = observe(note)
    assert after.get('exists'), 'delete hard-deleted the row instead of preserving a recoverable note'
    after = wait_for(note, lambda s: s.get('exists') and s['folderType'] == 1, 'note did not enter Recently Deleted')
    assert after['localVersion'] > before['localVersion'], 'deletion did not advance the cloud version'
    assert after['accountURI'] == before['accountURI'], 'deletion crossed accounts'
    assert after['text'] == before['text'], 'deletion changed note content'
    assert not call('get', '--id', note, check=False).returncode == 0, 'normal lookup still exposes a deleted note'
    assert call('delete', '--id', note, check=False).returncode != 0, 'a second delete must not permanently remove the note'
    after = wait_for(note, acknowledged, 'recoverable deletion did not reach iCloud')
    assert after['folderType'] == 1
    print(f'Deleted cloud version: {after["localVersion"]}/{after["syncedVersion"]}', flush=True)
    print('PASS: recoverable note retained, account/content preserved, normal lookups exclude it, iCloud acknowledged', flush=True)


if __name__ == '__main__':
    main()
