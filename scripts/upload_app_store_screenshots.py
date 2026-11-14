#!/usr/bin/env python3
"""Upload real simulator screenshots to an existing App Store localization.

Uses Apple's upload reservations and checksums. Re-running skips identical,
completed uploads and refuses to replace an existing image with different bytes.
"""
import argparse
import hashlib
import pathlib
import time
from urllib.parse import urlsplit

import requests

from asc import api, load_config, make_token


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--localization', required=True)
    parser.add_argument('--display-type', required=True)
    parser.add_argument('images', nargs='+', type=pathlib.Path)
    args = parser.parse_args()
    images = [(p, p.read_bytes()) for p in args.images]
    for path, blob in images:
        if not blob.startswith(b'\x89PNG\r\n\x1a\n'):
            raise SystemExit(f'{path}: expected a PNG screenshot')
    token = make_token(load_config())
    _, response = api(token, 'GET',
                      f'/appStoreVersionLocalizations/{args.localization}/appScreenshotSets')
    target = next((s for s in response['data']
                   if s['attributes']['screenshotDisplayType'] == args.display_type), None)
    if target is None:
        _, response = api(token, 'POST', '/appScreenshotSets', body={'data': {
            'type': 'appScreenshotSets',
            'attributes': {'screenshotDisplayType': args.display_type},
            'relationships': {'appStoreVersionLocalization': {'data': {
                'type': 'appStoreVersionLocalizations', 'id': args.localization}}}}})
        target = response['data']
    _, response = api(token, 'GET', f"/appScreenshotSets/{target['id']}/appScreenshots")
    existing = {s['attributes']['fileName']: s for s in response['data']}
    for path, blob in images:
        checksum = hashlib.md5(blob).hexdigest()
        name = path.name
        if name in existing:
            attrs = existing[name]['attributes']
            if (attrs.get('sourceFileChecksum') == checksum
                    and attrs.get('assetDeliveryState', {}).get('state') == 'COMPLETE'):
                print(f'{name}: already uploaded', flush=True)
                continue
            raise SystemExit(f'{name}: an existing upload needs inspection; not replacing it')
        _, response = api(token, 'POST', '/appScreenshots', body={'data': {
            'type': 'appScreenshots',
            'attributes': {'fileName': name, 'fileSize': len(blob)},
            'relationships': {'appScreenshotSet': {'data': {
                'type': 'appScreenshotSets', 'id': target['id']}}}}})
        shot = response['data']
        for operation in shot['attributes']['uploadOperations']:
            url = urlsplit(operation['url'])
            if url.scheme != 'https' or not url.hostname:
                raise SystemExit('Apple returned an invalid upload URL')
            start, size = operation['offset'], operation['length']
            result = requests.request(operation['method'], operation['url'],
                headers={h['name']: h['value'] for h in operation['requestHeaders']},
                data=blob[start:start + size], timeout=60, allow_redirects=False)
            if not 200 <= result.status_code < 300:
                raise SystemExit(f'{name}: upload returned HTTP {result.status_code}')
        api(token, 'PATCH', f"/appScreenshots/{shot['id']}", body={'data': {
            'type': 'appScreenshots', 'id': shot['id'],
            'attributes': {'uploaded': True, 'sourceFileChecksum': checksum}}})
        for _ in range(30):
            _, response = api(token, 'GET', f"/appScreenshots/{shot['id']}")
            state = response['data']['attributes']['assetDeliveryState']
            if state['state'] == 'COMPLETE':
                print(f'{name}: COMPLETE', flush=True)
                break
            if state['state'] == 'FAILED':
                raise SystemExit(f'{name}: processing failed: {state.get("errors")}')
            time.sleep(2)
        else:
            raise SystemExit(f'{name}: processing still pending; inspect before retrying')


if __name__ == '__main__':
    main()
