from pathlib import Path
import ctypes as c,json,hashlib,sys
base=Path(__file__).resolve().parent;controller=json.loads((base/('first-controller.json' if len(sys.argv)>2 and sys.argv[2]=='first' else 'run-1/controller.json')).read_text());root=Path(controller['root']);assert root.is_absolute() and root.name.startswith('aim-mac-lifecycle-') and not root.is_symlink() and (root/'.qa-owner').read_text()==controller['owner']
app=Path(controller['app']);assert app.is_relative_to(base/'run-1/source')
lib=c.CDLL(str(app/'Contents/Frameworks/sqlcipher.framework/sqlcipher'))
lib.sqlite3_open_v2.argtypes=[c.c_char_p,c.POINTER(c.c_void_p),c.c_int,c.c_char_p];lib.sqlite3_close.argtypes=[c.c_void_p];lib.sqlite3_prepare_v2.argtypes=[c.c_void_p,c.c_char_p,c.c_int,c.POINTER(c.c_void_p),c.POINTER(c.c_char_p)];lib.sqlite3_step.argtypes=[c.c_void_p];lib.sqlite3_column_count.argtypes=[c.c_void_p];lib.sqlite3_column_text.argtypes=[c.c_void_p,c.c_int];lib.sqlite3_column_text.restype=c.c_char_p;lib.sqlite3_finalize.argtypes=[c.c_void_p]
dbpath=root/'library/library.db';files=[dbpath]+[p for p in [Path(str(dbpath)+'-wal'),Path(str(dbpath)+'-shm')] if p.exists()];sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();before={str(p):sha(p) for p in files};db=c.c_void_p();assert lib.sqlite3_open_v2(str(dbpath).encode(),c.byref(db),1,None)==0

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
 query('PRAGMA key = "x\''+'75'*32+'\'"');query('PRAGMA query_only=ON')
 assert query('PRAGMA integrity_check')==[['ok']]
 item=query('SELECT i.id,i.name,d.name FROM information_items i LEFT JOIN information_directories d ON i.directory_id=d.id');fields=query('SELECT id,item_id,value FROM information_fields')
 association=json.loads((root/'synthetic-association.json').read_text());assert item==[[association['item'],'Synthetic','Mac Native QA']],item
 assert fields==[[association['field'],association['item'],'synthetic']],fields
 facts={'stage':sys.argv[1] if len(sys.argv)>1 else 'after-actual-GUI-save','SQLITE_OPEN_READONLY':True,'cipherVersion':query('PRAGMA cipher_version')[0][0],'schema':int(query('PRAGMA user_version')[0][0]),'integrity':'ok','informationCount':1,'directoryCount':int(query('SELECT COUNT(*) FROM information_directories')[0][0]),'actualGUISelectedDirectory':'Mac Native QA','originalInformationAndFieldIDsPreserved':True,'originalFieldValuePreserved':True}
finally:assert lib.sqlite3_close(db)==0
assert all(sha(p)==before[str(p)] for p in files);facts['databaseAndWalAndShmReadBytesUnchanged']=True
(base/(facts['stage']+'.json')).write_text(json.dumps(facts,indent=2)+'\n');print(json.dumps(facts))
