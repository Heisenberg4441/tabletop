#!/usr/bin/env python3
"""
extract-strings.py — the genstrings this machine does not have.

genstrings ships with Xcode, and this project is built with the Command Line
Tools alone, so the keys of every NSLocalizedString call are pulled out here
instead. The key has to come out byte-for-byte as Swift would build it at run
time, or the lookup silently misses and the English text shows through, so
multi-line literals get Swift's own rules: indentation stripped to the closing
delimiter, a trailing backslash joining lines, escapes decoded.

Usage: Tools/extract-strings.py Sources > keys.json      (key -> comment)
"""
import json, os, re, sys

def decode_escapes(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == '\\' and i + 1 < len(s):
            n = s[i + 1]
            if n == 'n': out.append('\n'); i += 2; continue
            if n == 't': out.append('\t'); i += 2; continue
            if n == 'r': out.append('\r'); i += 2; continue
            if n == '0': out.append('\0'); i += 2; continue
            if n in '"\'\\': out.append(n); i += 2; continue
            if n == 'u' and i + 2 < len(s) and s[i + 2] == '{':
                j = s.index('}', i)
                out.append(chr(int(s[i + 3:j], 16))); i = j + 1; continue
            if n == '(':
                raise ValueError('interpolation')
        out.append(c); i += 1
    return ''.join(out)

def multiline(body):
    # body = text between the opening """ and the closing """ (exclusive)
    assert body.startswith('\n')
    lines = body[1:].split('\n')
    indent = lines[-1]                      # the closing delimiter's own line
    assert indent.strip() == ''
    lines = lines[:-1]
    result = []
    for line in lines:
        result.append(line[len(indent):] if line.startswith(indent) else line.lstrip())
    text = ''
    for k, line in enumerate(result):
        if line.endswith('\\') and not line.endswith('\\\\'):
            text += line[:-1]
        else:
            text += line + ('\n' if k < len(result) - 1 else '')
    return decode_escapes(text)

CALL = re.compile(r'NSLocalizedString\(\s*')
def scan(src):
    found = []
    for m in CALL.finditer(src):
        i = m.end()
        if src.startswith('"""', i):
            j = src.index('"""', i + 3)
            raw = src[i + 3:j]; end = j + 3
            try: key = multiline(raw)
            except ValueError: continue
        elif src.startswith('"', i):
            j = i + 1
            while src[j] != '"':
                j += 2 if src[j] == '\\' else 1
            raw = src[i + 1:j]; end = j + 1
            try: key = decode_escapes(raw)
            except ValueError: continue
        else:
            continue
        cm = re.match(r'\s*,\s*comment:\s*"((?:[^"\\]|\\.)*)"', src[end:end + 400])
        found.append((key, decode_escapes(cm.group(1)) if cm else ''))
    return found

keys = {}
for root, _, files in os.walk(sys.argv[1]):
    for f in sorted(files):
        if f.endswith('.swift'):
            path = os.path.join(root, f)
            for key, comment in scan(open(path, encoding='utf-8').read()):
                keys.setdefault(key, comment or os.path.relpath(path, sys.argv[1]))
json.dump(keys, sys.stdout, ensure_ascii=False, indent=1)
