#!/usr/bin/env python3
"""Swift kaynaklarındaki kullanıcıya görünen Türkçe metinleri L("…") ile sarar (yerelleştirme için).

Kullanım: sar.py [--yaz] dosya.swift…
--yaz verilmezse yalnız aday metinleri listeler.

Sarılmayanlar: zaten yerelleştirilen SwiftUI çağrılarına tek başına verilen metinler (Text("…") gibi),
ayar anahtarları, simge adları, sözlük anahtarları ve zaten L(…) içinde olanlar.
"""
import re, sys

LOCALIZED_CALLS = ('Text(', 'Button(', 'Toggle(', 'Label(', 'Section(', '.navigationTitle(', 'TextField(', 'SecureField(',
                   'Picker(', 'NavigationLink(', '.accessibilityLabel(', '.confirmationDialog(', '.alert(',
                   'ContentUnavailableView(', 'description: Text(')
SKIP_BEFORE = ('forKey: ', 'systemImage: ', 'systemName: ', 'named: ', 'label: ', 'L(', 'String(localized: ', 'kSec',
               'forHTTPHeaderField: ', 'withAllowedCharacters', 'print(', 'fatalError(', 'id: ', 'name: "marhilk"',
               'AppStorage(', 'suiteName: ', 'case ', '== ', '!= ', 'hasPrefix(', 'hasSuffix(', 'contains(',
               'components(separatedBy: ', 'string: ', 'URLQueryItem(', 'value: ', 'queue: ', 'DispatchQueue(label: ')
TURKISH = re.compile(r'[çğıöşüÇĞİÖŞÜ]')

def literals(src):
    """(başlangıç, bitiş) çiftleri: en dıştaki çift tırnaklı metinler (yorumlar ve iç içe olanlar hariç)."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith('//', i):
            i = src.find('\n', i)
            if i < 0: break
            continue
        if src.startswith('/*', i):
            i = src.find('*/', i) + 2
            continue
        if src.startswith('#"""', i) or src.startswith('"""', i):
            end = src.find('"""#' if src[i] == '#' else '"""', i + 4)
            i = end + 4
            continue
        if c == '"':
            j, depth = i + 1, 0
            while j < n:
                if src[j] == '\\' and depth == 0:
                    if src[j + 1] == '(':
                        depth = 1; j += 2; continue
                    j += 2; continue
                if depth > 0:
                    if src[j] == '(': depth += 1
                    elif src[j] == ')': depth -= 1
                    elif src[j] == '"':        # iç içe metin: atla
                        k = j + 1
                        while src[k] != '"' or src[k - 1] == '\\': k += 1
                        j = k
                    j += 1; continue
                if src[j] == '"': break
                j += 1
            out.append((i, j + 1))
            i = j + 1
            continue
        i += 1
    return out

def candidate(src, a, b):
    text = src[a + 1:b - 1]
    plain = re.sub(r'\\\(.*?\)', '', text)
    if len(plain.strip()) < 2: return False
    single = re.fullmatch(r"[A-ZÇĞİÖŞÜ][a-zçğıöşü']{3,}", plain.strip())     # "Devam", "Genel" gibi tek kelime
    if not (TURKISH.search(plain) or ' ' in plain.strip() or single): return False
    line_start = src.rfind('\n', 0, a) + 1
    if re.search(r'"(app|samsung)":', src[line_start:a]): return False              # teşhis iletisi, kullanıcı görmez
    if re.fullmatch(r'[A-Za-z0-9_.\-:/ %@]+', plain) and ' ' not in plain.strip(): return False
    before = src[max(0, a - 60):a]
    after = src[b:b + 3].lstrip()
    for skip in SKIP_BEFORE:
        if before.endswith(skip): return False
    if re.search(r'\[\s*$', before) and after.startswith(':'): return False       # sözlük anahtarı
    if re.search(r',\s*$', before) and after.startswith(':'): return False
    if after.startswith(':') and not re.search(r'\?\s*$', before): return False     # "anahtar": değer
    tail = before.rstrip()
    for call in LOCALIZED_CALLS:
        if tail.endswith(call) and (after.startswith(')') or after.startswith(',')):
            return False                                                           # zaten yerelleştirilen çağrı
    return True

def main():
    write = '--yaz' in sys.argv
    total = 0
    for path in [p for p in sys.argv[1:] if p != '--yaz']:
        src = open(path, encoding='utf-8').read()
        picks = [(a, b) for a, b in literals(src) if candidate(src, a, b)]
        total += len(picks)
        if write:
            for a, b in reversed(picks):
                src = src[:a] + 'L(' + src[a:b] + ')' + src[b:]
            open(path, 'w', encoding='utf-8').write(src)
        else:
            for a, b in picks:
                line = src.count('\n', 0, a) + 1
                print(f'{path.split("/")[-1]}:{line}: {src[max(0, a - 28):a].split(chr(10))[-1].strip()[-26:]:>26} ▸ {src[a:b][:90]}')
    print(f'toplam {total} metin', file=sys.stderr)

main()
