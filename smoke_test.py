"""Exercise real local generation using a synthetic system voice, not user data."""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile

import numpy as np
import soundfile as sf
from worker import PROMPT, validate

ROOT = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='voice-lab-test-') as directory:
    path = Path(directory)
    sf.write(path / 'silent.wav', np.zeros(24000 * 6), 24000)
    try:
        validate(path / 'silent.wav')
        raise AssertionError('Silent recording was accepted')
    except ValueError as exc:
        assert 'quiet' in str(exc)
    subprocess.run(['/usr/bin/say', '-v', 'Samantha', '-o', str(path / 'fixture.aiff'), PROMPT], check=True)
    audio, sr = sf.read(path / 'fixture.aiff')
    sf.write(path / 'pending.wav', audio, sr)
    env = dict(os.environ, VOICE_LAB_TEST_DATA=str(path))
    requests = [{'action': 'reference'}, {'action': 'generate', 'language': 'Spanish', 'text': 'Hola, me gustaría reservar una mesa para dos personas.'}, {'action': 'generate', 'language': 'English', 'text': 'Hello, this is a local voice test.'}, {'action': 'generate', 'language': 'Tagalog', 'text': 'Kumusta, magandang araw. Maraming salamat sa iyong tulong.'}]
    child = subprocess.Popen([sys.executable, '-u', str(ROOT / 'worker.py')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
    child.stdin.write(''.join(json.dumps(r) + '\n' for r in requests)); child.stdin.close()
    events = []
    for line in child.stdout:
        print(line, end='', flush=True)
        events.append(json.loads(line))
    assert child.wait() == 0
    assert not any(e['event'] in ('error', 'fatal') for e in events), events
    assert len([e for e in events if e['event'] == 'generated']) == 3, events
    speech, sr = sf.read(path / 'speech.wav')
    assert len(speech) / sr > 1 and np.isfinite(speech).all() and np.max(np.abs(speech)) > 0.01
    (ROOT / 'build' / 'smoke-test.json').write_text(json.dumps(events, indent=2))
    print('PASS: silence rejection, sample validation, English generation, Tagalog generation, Spanish generation, non-silent WAV.')
