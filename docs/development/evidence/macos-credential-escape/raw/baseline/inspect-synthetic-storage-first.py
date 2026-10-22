from pathlib import Path
import json,ctypes,hashlib,sys

out=Path(__file__).resolve().parent
c=json.loads((out/'controller.json').read_text());state=json.loads((out/'result.json').read_text())
root=Path(c['root']);assert root.name.startswith('aim-editor-focus-') and not root.is_symlink()
assert (root/'.qa-owner').read_text()==state['bundleIdentifier'].split('.')[-1]
dbfile=root/'library/library.db';assert dbfile.is_file()
library=Path(c['app'])/'Contents/Frameworks/sqlcipher.framework/Versions/A/sqlcipher'
lib=ctypes.CDLL(str(library))
ptr=ctypes.c_void_p
lib.sqlite3_open_v2.argtypes=[ctypes.c_char_p,ctypes.POINTER(ptr),ctypes.c_int,ctypes.c_char_p]
lib.sqlite3_open_v2.restype=ctypes.c_int
lib.sqlite3_key.argtypes=[ptr,ptr,ctypes.c_int];lib.sqlite3_key.restype=ctypes.c_int
lib.sqlite3_db_readonly.argtypes=[ptr,ctypes.c_char_p];lib.sqlite3_db_readonly.restype=ctypes.c_int
lib.sqlite3_prepare_v2.argtypes=[ptr,ctypes.c_char_p,ctypes.c_int,ctypes.POINTER(ptr),ctypes.POINTER(ctypes.c_char_p)]
lib.sqlite3_prepare_v2.restype=ctypes.c_int
lib.sqlite3_step.argtypes=[ptr];lib.sqlite3_step.restype=ctypes.c_int
lib.sqlite3_column_text.argtypes=[ptr,ctypes.c_int];lib.sqlite3_column_text.restype=ctypes.c_char_p
lib.sqlite3_finalize.argtypes=[ptr];lib.sqlite3_close.argtypes=[ptr]
def hashes():
 return {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [dbfile,Path(str(dbfile)+'-wal')] if p.exists()}
before=hashes();db=ptr();assert lib.sqlite3_open_v2(str(dbfile).encode(),ctypes.byref(db),1,None)==0
try:
 key=ctypes.create_string_buffer(bytes([158])*32);assert lib.sqlite3_key(db,key,32)==0
 assert lib.sqlite3_db_readonly(db,b'main')==1
 def query(sql):
  statement=ptr();assert lib.sqlite3_prepare_v2(db,sql.encode(),-1,ctypes.byref(statement),None)==0
  rows=[]
  try:
   while True:
    result=lib.sqlite3_step(statement)
    if result==101:return rows
    assert result==100,result
    rows.append(lib.sqlite3_column_text(statement,0).decode())
  finally:lib.sqlite3_finalize(statement)
 cipher=query('PRAGMA cipher_version')[0]
 credentials=[json.loads(x) for x in query('SELECT payload FROM managed_credentials')]
 materials=[json.loads(x) for x in query('SELECT payload FROM credential_materials ORDER BY version')]
 assert len(credentials)==1 and credentials[0]['name']=='KeyboardSynthetic'
 expected=int(sys.argv[1]);assert credentials[0]['version']==expected
 assert [m['version'] for m in materials]==list(range(1,expected+1))
 known=[b'KeyboardSecret42',b'KeyboardRotated42']
 exact=[bytes(m['bytes'])==known[m['version']-1] for m in materials]
 assert all(exact)
finally:lib.sqlite3_close(db)
after=hashes();assert before==after
record={'phase':c['mode'],'currentVersion':expected,'credentialCount':len(credentials),'materialVersions':[m['version'] for m in materials],'knownSyntheticBytesExact':exact,'sqliteReadOnly':True,'cipherVersion':cipher,'dbAndWalHashesUnchanged':True,'hashes':after,'productionKeychainUsed':False,'plainValuesLogged':False}
(out/('storage-'+c['mode']+'-v'+str(expected)+'.json')).write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record,indent=2))
