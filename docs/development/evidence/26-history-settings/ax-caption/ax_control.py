import json,sys,uuid,time
from pathlib import Path
root=Path(json.loads(Path('.scratch/ax-probe/current.json').read_text(encoding='utf-8'))['root'])
nonce=uuid.uuid4().hex
payload={'nonce':nonce,'action':sys.argv[1],'phase':sys.argv[2] if len(sys.argv)>2 else sys.argv[1]}
temporary=root/'control-next.json';temporary.write_text(json.dumps(payload),encoding='utf-8');temporary.replace(root/'control.json')
print(json.dumps(payload))
