#!/usr/bin/env python3
"""Exercise account detection and quota reads without real login credentials."""
import json
import os
import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
app = root / 'dist/近星点.app'
binary = app / 'Contents/MacOS/TokenTank'
version = json.loads((root / 'version.json').read_text())
with (app / 'Contents/Info.plist').open('rb') as source:
    plist = plistlib.load(source)
assert plist['CFBundleIdentifier'] == version['bundleIdentifier']
assert plist['CFBundleShortVersionString'] == version['version']
assert plist['CFBundleVersion'] == str(version['build'])

fixture = r'''
import json, os, sys
mode = os.environ['TOKEN_TANK_FIXTURE']
if sys.argv[1] == '--version':
    print('not-codex' if mode == 'invalid' else 'codex-cli 0.149.0')
    sys.exit(0)
assert sys.argv[1] == 'app-server'
initialized = False
for line in sys.stdin:
    request = json.loads(line)
    method = request['method']
    if method == 'initialize':
        assert request['params']['clientInfo']['version'] == os.environ['TOKEN_TANK_VERSION']
        result = {}
    elif method == 'initialized':
        initialized = True
        continue
    elif method == 'account/read':
        assert initialized
        result = {'account': None if mode == 'logged_out' else {'type': 'apiKey' if mode == 'api_key' else 'chatgpt', 'planType': 'future_plan' if mode == 'unknown_plan' else 'prolite'}}
    elif method == 'account/rateLimits/read':
        if mode in ('old_cli', 'expired', 'network'):
            codes = {'old_cli': -32601, 'expired': -32000, 'network': -32000}
            messages = {'old_cli': 'Method not found', 'expired': '401 Unauthorized', 'network': 'Network unavailable'}
            print(json.dumps({'id': request['id'], 'error': {'code': codes[mode], 'message': messages[mode]}}), flush=True)
            continue
        result = {'rateLimits': {'planType': 'promax' if mode == 'bucket_plan' else None, 'primary': {'usedPercent': 25, 'windowDurationMins': 10080, 'resetsAt': 1890000000}}, 'rateLimitResetCredits': {'availableCount': 2}}
    else:
        raise AssertionError(method)
    print(json.dumps({'id': request['id'], 'result': result}), flush=True)
'''
with tempfile.TemporaryDirectory(prefix='token-tank-cli-') as directory:
    cli = Path(directory) / "Codex user's CLI"
    cli.write_text('#!' + sys.executable + '\n' + fixture)
    cli.chmod(0o755)
    cases = [
        ('ready', True, 'Pro 100'),
        ('unknown_plan', True, 'future_plan'),
        ('bucket_plan', True, 'Pro 500'),
        ('logged_out', False, 'ChatGPT'),
        ('api_key', False, 'API Key'),
        ('old_cli', False, '更新 Codex CLI'),
        ('expired', False, '401'),
        ('network', False, 'Network unavailable'),
        ('invalid', False, '不是可用的 Codex CLI'),
    ]
    for mode, success, expected in cases:
        environment = dict(os.environ, TOKEN_TANK_FIXTURE=mode, TOKEN_TANK_VERSION=version['version'])
        result = subprocess.run([str(binary), '--probe', '--cli-path', str(cli)], env=environment, capture_output=True, text=True, timeout=35)
        assert (result.returncode == 0) == success, (mode, result.stdout, result.stderr)
        assert expected in result.stdout + result.stderr, (mode, result.stdout, result.stderr)
        print('PASS:', mode)
    result = subprocess.run([str(binary), '--probe', '--cli-path', str(Path(directory) / 'missing')], capture_output=True, text=True, timeout=5)
    assert result.returncode != 0 and '尚未找到' in result.stderr
    print('PASS: missing CLI')
