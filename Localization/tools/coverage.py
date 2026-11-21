# Lists English literals in Swift sources that the compiler did not extract as localizable.
import json, re, sys, glob, os
D, src = sys.argv[1], sys.argv[2:]
keys = set()
for f in glob.glob(D + '/**/*.stringsdata', recursive=True):
    for t in json.load(open(f))['tables'].values():
        for e in t: keys.add(e['key'])
def norm(k): return re.sub(r'%(\d+\$)?(lld|ld|d|@|f|lf|\.\d+f|u|llu)', '\x00', k).replace('%%', '%')
nk = {norm(k) for k in keys}

def literals(text):
    """Yield (line, value-with-interpolations-as-NUL) for each top-level string literal, nested ones too."""
    i, n, line = 0, len(text), 1
    out = []
    def string(i, line):  # at opening quote
        start_line = line; i += 1; buf = []
        while i < n:
            c = text[i]
            if c == '\\' and i + 1 < n and text[i+1] == '(':
                i += 2; depth = 1
                while i < n and depth:
                    if text[i] == '"':
                        i, line = string(i, line); continue
                    if text[i] == '(': depth += 1
                    elif text[i] == ')': depth -= 1
                    elif text[i] == '\n': line += 1
                    i += 1
                buf.append('\x00'); continue
            if c == '\\': buf.append({'n': '\n', '"': '"', '\\': '\\', 't': '\t'}.get(text[i+1], text[i+1])); i += 2; continue
            if c == '"': out.append((start_line, ''.join(buf))); return i + 1, line
            if c == '\n': line += 1
            buf.append(c); i += 1
        return i, line
    while i < n:
        c = text[i]
        if text.startswith('//', i):
            j = text.find('\n', i); i = n if j < 0 else j; continue
        if text.startswith('"""', i):
            j = text.find('"""', i + 3); line += text.count('\n', i, j); i = j + 3; continue
        if c == '"': i, line = string(i, line); continue
        if c == '\n': line += 1
        i += 1
    return out

for path in src:
    text = open(path).read()
    lines = text.split('\n')
    for ln, v in literals(text):
        src_line = lines[ln - 1]
        if 'print(' in src_line or 'Logger' in src_line or 'appendingPathComponent' in src_line: continue
        if not re.search(r'[A-Za-z]{3,}', v) or (' ' not in v and not re.fullmatch(r'[A-Z][a-z]+…?', v)): continue
        if v in nk: continue
        print(f"{os.path.basename(path)}:{ln}: {v.replace(chr(0), '{}')[:120]!r}")
