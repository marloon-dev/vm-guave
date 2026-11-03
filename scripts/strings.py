#!/usr/bin/env python3
"""Textos da interface do app Mac.

    ./scripts/strings.py check    lista textos sem tradução (e traduções que sobraram) por idioma
    ./scripts/strings.py keys     imprime todos os textos, um por linha (JSON)

O texto-fonte é o português do Brasil escrito no código: Text("..."), Button("..."),
String(localized: "...") etc. O compilador extrai esses textos (-emit-localized-strings);
cada idioma traduz em Resources/Localization/<idioma>.lproj/Localizable.strings.
O pt-BR não precisa de arquivo cheio: texto sem tradução aparece como está no código.
"""
import glob, json, os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOC = os.path.join(ROOT, 'Resources', 'Localization')
SOURCE_LANG = 'pt-BR'


def extract_keys():
    env = dict(os.environ)
    if 'DEVELOPER_DIR' not in env and os.path.isdir('/Applications/Xcode.app'):
        env['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, 'out')
        os.makedirs(out)
        # Pasta de build própria: um build incremental pularia arquivos e perderia textos.
        subprocess.run(
            ['swift', 'build', '-c', 'debug', '--product', 'BootGuave', '--scratch-path', os.path.join(tmp, 'build'),
             '-Xswiftc', '-emit-localized-strings', '-Xswiftc', '-emit-localized-strings-path', '-Xswiftc', out],
            cwd=ROOT, env=env, check=True, stdout=subprocess.DEVNULL)
        keys = set()
        for f in glob.glob(os.path.join(out, '*.stringsdata')):
            for entries in json.load(open(f)).get('tables', {}).values():
                keys.update(e['key'] for e in entries)
    return keys


STRING_RE = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')


def unescape(s):
    return re.sub(r'\\(.)', lambda m: {'n': '\n', 't': '\t'}.get(m.group(1), m.group(1)), s)


def read_strings(path):
    text = open(path, encoding='utf-8').read()
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return {unescape(k): unescape(v) for k, v in STRING_RE.findall(text)}


def placeholders(s):
    """Marcadores de formato, sem o índice de posição (%2$@ conta como %@)."""
    return sorted(re.sub(r'\d+\$', '', p) for p in re.findall(r'%(?:\d+\$)?(?:lld|ld|u|d|@|f|\.\d+f|%)', s))


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'check'
    keys = extract_keys()
    if cmd == 'keys':
        print(json.dumps(sorted(keys), ensure_ascii=False, indent=1))
        return
    problems = 0
    for lproj in sorted(glob.glob(os.path.join(LOC, '*.lproj'))):
        lang = os.path.basename(lproj)[:-6]
        if lang == SOURCE_LANG:
            continue
        table = read_strings(os.path.join(lproj, 'Localizable.strings'))
        missing = sorted(keys - table.keys())
        stale = sorted(table.keys() - keys)
        bad = [k for k in keys & table.keys() if placeholders(k) != placeholders(table[k])]
        print(f'{lang}: {len(keys) - len(missing)}/{len(keys)} traduzidos'
              + (f', {len(stale)} sobrando' if stale else '') + (f', {len(bad)} com %@/%lld errados' if bad else ''))
        for k in missing: print(f'   falta: {k!r}')
        for k in stale: print(f'   sobra: {k!r}')
        for k in bad: print(f'   formato: {k!r} -> {table[k]!r}')
        problems += len(missing) + len(bad)
    sys.exit(1 if problems else 0)


if __name__ == '__main__':
    main()
