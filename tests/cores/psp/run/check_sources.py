"""PSP policy check: no .inc files or textual Pascal implementation imports."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[4]
SCOPES = (ROOT / 'source/cores/psp', Path(__file__).parent, ROOT / 'source/gpu/shaders',
          ROOT / 'tests/gpu/vulkan', ROOT / 'tests/gpu/vulkan/shaders')
bad = []
for scope in SCOPES:
    for path in scope.iterdir():
        if not path.is_file():
            continue
        if path.suffix.lower() == '.inc':
            bad.append(str(path.relative_to(ROOT)))
        elif path.suffix.lower() in ('.pas', '.dpr'):
            text = path.read_text(encoding='utf-8-sig')
            if re.search(r'\{\$(?:I|INCLUDE)\s+[^}]+\.(?:inc|pas)\s*\}', text, re.I):
                bad.append(str(path.relative_to(ROOT)))
for path in (ROOT / 'source/cores/psp').glob('*.pas'):
    if path.name.startswith('PSP.State.') or path.name == 'PSP.Kernel.pas':
        continue
    text = path.read_text(encoding='utf-8-sig')
    if re.search(r'\b(?:FKernel|K)\.AddTimer\s*\(|\.OnExit\s*:=\s*procedure', text):
        bad.append(str(path.relative_to(ROOT)) + ' (opaque persistent callback)')
if bad:
    raise SystemExit('Forbidden PSP includes: ' + ', '.join(bad))
print('PASS PSP sources: no .inc/disguised includes or opaque service timers/exit hooks')
