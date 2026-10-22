from pathlib import Path
import ctypes as c,hashlib,json
b=Path(__file__).resolve().parent;controller=json.loads((b/'controller.json').read_text());state=json.loads((b/'result.json').read_text());root=Path(controller['root']);owner=state['bundleIdentifier'].rsplit('.',1)[1]
assert root.is_absolute() and root.name.startswith('aim-editor-focus-') and not root.is_symlink() and (root/'.qa-owner').read_text()==owner
app=Path(controller['app']);assert app.is_relative_to(b/'source')
lib=c.CDLL(str(app/'Contents/Frameworks/sqlcipher.framework/sqlcipher'))
lib.sqlite3_open_v2.argtypes=[c.c_char_p,c.POINTER(c.c_void_p),c.c_int,c.c_char_p];lib.sqlite3_close.argtypes=[c.c_void_p];lib.sqlite3_prepare_v2.argtypes=[c.c_void_p,c.c_char_p,c.c_int,c.POINTER(c.c_void_p),c.POINTER(c.c_char_p)];lib.sqlite3_step.argtypes=[c.c_void_p];lib.sqlite3_column_count.argtypes=[c.c_void_p];lib.sqlite3_column_text.argtypes=[c.c_void_p,c.c_int];lib.sqlite3_column_text.restype=c.c_char_p;lib.sqlite3_finalize.argtypes=[c.c_void_p]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();dbpath=root/'library/library.db';files=[p for p in [dbpath,Path(str(dbpath)+'-wal'),Path(str(dbpath)+'-shm')] if p.exists()];before={str(p):sha(p) for p in files};db=c.c_void_p();assert lib.sqlite3_open_v2(str(dbpath).encode(),c.byref(db),1,None)==0

def query(sql):
 st=c.c_void_p();assert lib.sqlite3_prepare_v2(db,sql.encode(),-1,c.byref(st),None)==0
 out=[]
 try:
  while True:
   code=lib.sqlite3_step(st)
   if code==101:return out
   assert code==100,code
   out.append([lib.sqlite3_column_text(st,i).decode() if lib.sqlite3_column_text(st,i) is not None else None for i in range(lib.sqlite3_column_count(st))])
 finally:lib.sqlite3_finalize(st)
try:
 query('PRAGMA key = "x\''+'9e'*32+'\'"');query('PRAGMA query_only=ON');assert query('PRAGMA integrity_check')==[['ok']]
 rows=query('SELECT name,description FROM information_items');assert rows==[['Mac 焦点合成资料','BaselineDescription']],rows
 assert query("SELECT value FROM information_fields WHERE name='合成字段'")==[['BaselineValue']]
 templates=query('SELECT name,description,version,fields_json FROM field_templates');assert len(templates)==1
 t=templates[0];assert t[:3]==['SyntheticNativeTemplate','Synthetic template description','1'],t
 fields=json.loads(t[3]);assert len(fields)==1 and fields[0]['name']=='SyntheticField',fields
 assert query('SELECT count(*) FROM managed_credentials')==[['0']]
 facts={'SQLITE_OPEN_READONLY':True,'cipherVersion':query('PRAGMA cipher_version')[0][0],'schema':int(query('PRAGMA user_version')[0][0]),'integrity':'ok','template':{'name':t[0],'description':t[1],'version':int(t[2]),'fields':fields},'originalInformationUnchanged':True,'credentialDraftDiscardedWithoutPersisting':True,'readOnlyConnectionIsNotAppProcessReopen':True}

finally:assert lib.sqlite3_close(db)==0
assert all(sha(p)==before[str(p)] for p in files);facts['databaseWalShmBytesUnchanged']=True
(b/'template-sqlcipher-readonly.json').write_text(json.dumps(facts,ensure_ascii=False,indent=2)+'\n');print(json.dumps(facts,ensure_ascii=False))
