import hashlib,json,os,sys
print(json.dumps({'phase':'ready','pid':os.getpid()}),flush=True)
data=sys.stdin.buffer.read()
print(json.dumps({'phase':'received','sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)}),flush=True)
