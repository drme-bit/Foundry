#!/usr/bin/env python3
"""Check the public package locally; never publish or modify installed dependencies."""
from pathlib import Path
import importlib.util
import json
import os
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent.parent

def main():
    env = dict(os.environ)
    env['PATH'] = os.pathsep.join([env.get('PATH', ''), str(Path.home()/'.aftman/bin'), '/opt/homebrew/bin'])
    tools = {}
    for name in ['luau', 'luau-analyze', 'luau-compile', 'rojo', 'wally']:
        tools[name] = shutil.which(name, path=env['PATH'])
        if not tools[name]: raise SystemExit('Missing tool: ' + name)
    def run(name, args):
        result = subprocess.run(args, cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
        if result.returncode:
            print(result.stdout + result.stderr)
            raise SystemExit('FAIL ' + name)
        print('PASS ' + name, flush=True)
        return result.stdout
    if not (ROOT/'Packages/t.lua').exists() or not (ROOT/'Packages/Trove.lua').exists():
        raise SystemExit('Run wally install first')
    build = ROOT/'build'; build.mkdir(exist_ok=True)
    run('strict source types', [tools['luau-analyze'], 'src'])
    sources = sorted((ROOT/'src').rglob('*.luau')) + sorted((ROOT/'tests').rglob('*.luau'))
    for path in sources:
        result = subprocess.run([tools['luau-compile'], str(path)], cwd=ROOT, env=env,
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        if result.returncode: raise SystemExit(f'{path}: {result.stderr}')
    print(f'PASS syntax: {len(sources)} source/test modules', flush=True)
    suite_output = run('portable suites', [tools['luau'], 'tests/run.luau'])
    print(suite_output.strip().splitlines()[-1])
    spec = importlib.util.spec_from_file_location('dependency_fixture', ROOT/'tests/dependencies.py')
    fixture = importlib.util.module_from_spec(spec); spec.loader.exec_module(fixture)
    with tempfile.TemporaryDirectory(prefix='foundry-dependency-check-') as directory:
        path = fixture.prepare(directory)
        output = run('real dependency integration', [tools['luau'], str(path)])
        print(output.strip().splitlines()[-1])
    docs = [ROOT/'README.md', ROOT/'CONTRIBUTING.md', ROOT/'CHANGELOG.md', *sorted((ROOT/'docs').rglob('*.md'))]
    errors = []
    for path in docs:
        text = path.read_text()
        if re.search(r'[\u0400-\u04ff]', text): errors.append(f'{path}: non-English documentation')
        for target in re.findall(r'\[[^\]]*\]\(([^)]+)\)', text):
            if '://' in target or target.startswith('mailto:'): continue
            filename, _, anchor = target.partition('#')
            linked = (path.parent/filename).resolve() if filename else path
            if not linked.exists(): errors.append(f'{path}: missing link {target}'); continue
            if anchor and linked.suffix == '.md':
                headings = re.findall(r'^#{1,6}\s+(.+)$', linked.read_text(), re.M)
                slugs = [re.sub(r'[^\w\- ]', '', h.lower()).replace(' ', '-') for h in headings]
                if anchor not in slugs: errors.append(f'{path}: missing anchor {target}')
    if errors: raise SystemExit('\n'.join(errors))
    print(f'PASS English documentation and links: {len(docs)} files', flush=True)
    for project, output in [('default.project.json', 'Foundry-source.rbxmx'), ('model.project.json', 'Foundry.rbxmx')]:
        model = build/output
        run(project, [tools['rojo'], 'build', project, '-o', str(model)])
        count = 0
        with tempfile.TemporaryDirectory(prefix='foundry-model-check-') as directory:
            for item in ET.parse(model).getroot().iter('Item'):
                source = next((p for p in item.findall('Properties/*') if p.get('name') == 'Source'), None)
                if source is None: continue
                path = Path(directory)/f'{count}.luau'; path.write_text(source.text or '')
                result = subprocess.run([tools['luau-compile'], str(path)], env=env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
                if result.returncode: raise SystemExit(result.stderr)
                count += 1
        print(f'PASS {project}: {count} embedded modules', flush=True)
    archive = build/'foundry-0.1.0.zip'
    run('Wally archive', [tools['wally'], 'package', '--output', str(archive)])
    with zipfile.ZipFile(archive) as packaged:
        names = packaged.namelist()
        for required in ['wally.toml', 'default.project.json', 'src/init.luau', 'LICENCE', 'THIRD_PARTY_NOTICES.md']:
            if required not in names: raise SystemExit('Missing archive file: ' + required)
        forbidden = ['Packages/', 'tests/', 'scripts/', 'docs/', 'build/']
        if any(n.startswith(prefix) for n in names for prefix in forbidden):
            raise SystemExit('Development/generated files leaked into the Wally archive')
        if 'model.project.json' in names: raise SystemExit('Bundled-model project leaked into Wally archive')
    report = { 'Passed': True, 'SourceModules': len(sources), 'DocumentationFiles': len(docs),
               'PortableSuites': suite_output.strip().splitlines()[-1], 'ArchiveFiles': len(names) }
    (build/'check-report.json').write_text(json.dumps(report, indent=2)+'\n')
    print('PASS Foundry package checks', flush=True)

if __name__ == '__main__': main()
