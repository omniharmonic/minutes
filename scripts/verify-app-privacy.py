#!/usr/bin/env python3
"""Reject app packages whose executable lacks its own TCC usage metadata."""
import pathlib, plistlib, struct, sys

app = pathlib.Path(sys.argv[1])
outer = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
blob = (app / 'Contents/MacOS' / outer['CFBundleExecutable']).read_bytes()
assert struct.unpack_from('<I', blob)[0] == 0xfeedfacf, 'Expected native arm64 Mach-O executable'
commands = struct.unpack_from('<I', blob, 16)[0]
position = 32
embedded = None
for _ in range(commands):
    command, length = struct.unpack_from('<II', blob, position)
    if command == 0x19:
        sections = struct.unpack_from('<I', blob, position + 64)[0]
        for index in range(sections):
            section = position + 72 + index * 80
            name, segment, address, size, offset = struct.unpack_from('<16s16sQQI', blob, section)
            if name.rstrip(b'\0') == b'__info_plist':
                embedded = plistlib.loads(blob[offset:offset + size])
    position += length
assert embedded is not None, 'Missing embedded __TEXT,__info_plist; direct launches can inherit the parent privacy identity'
for key in ['CFBundleIdentifier', 'NSSpeechRecognitionUsageDescription', 'NSMicrophoneUsageDescription', 'NSCalendarsFullAccessUsageDescription', 'NSAudioCaptureUsageDescription']:
    assert isinstance(outer.get(key), str) and outer[key].strip(), 'Missing bundle privacy field: ' + key
    assert embedded.get(key) == outer[key], 'Embedded/bundle metadata mismatch: ' + key
print('Executable and app-bundle privacy metadata agree for Speech, microphone, Calendar and system audio.')
