// Reusable credential-grant target model; no actual command execution.
const reusableMerge=window.mergeViews;
window.mergeViews=base=>{
 const app=reusableMerge(base),init=app.init,approve=app.approveUse;
 Object.defineProperties(app,Object.getOwnPropertyDescriptors({
  selectedOperation:'',
  approveUse(){
   approve.call(this);
   if(new URLSearchParams(location.search).has('legacy'))return;
   const grant=this.grants.find(g=>g.id==='USE-'+this.requestId);
   if(grant){grant.reusable=true;grant.operations=[]}
   const fields=this.grants.find(g=>g.id==='FIELDS-'+this.requestId);
   if(fields)fields.expires='今天 22:40';
  },
  get reuseOperations(){return this.grant?.operations||[]},
  get reuseOperation(){return this.reuseOperations.find(op=>op.id===this.selectedOperation)||this.reuseOperations.at(-1)},
  recordPrototypeOperation(id,command,state='exited'){
   const grant=this.grant;if(!grant?.reusable||grant.state!=='有效')return 'grant_revoked';
   const old=grant.operations.find(op=>op.id===id);
   if(old)return old.command===command?old:'operation_conflict';
   const op={id,command,state,exitCode:state==='exited'?0:null,cleanup:state==='unknown'?'待核查':state==='running'?'等待本次进程组结束':'complete',time:'今天 14:45',planHash:'sha256:'+(grant.operations.length+1).toString(16).padStart(64,'0')};
   grant.operations.push(op);grant.reads=grant.operations.length;this.selectedOperation=id;return op;
  },
  revokeReusable(){if(this.grant?.reusable)this.grant.state='已撤销'},
  initializeReuse(){
   const state=new URLSearchParams(location.search).get('state')||'';
   if(!state.startsWith('reuse-'))return;
   this.requestId='REQ-026';this.page='approvals';
   if(state==='reuse-result'){this.approveUse();return}
   if(state!=='reuse-approval'){
    this.approveUse();this.flow='';this.page='history';this.historyId='USE-REQ-026';this.historyFilter='all';
    this.recordPrototypeOperation('OP-01','ssh -T -o BatchMode=yes -i {{file:ssh_key}} -p 2222 developer@test.beichen.example /usr/bin/true');
    if(state==='reuse-running'){const op=this.recordPrototypeOperation('OP-02','ssh -T -o BatchMode=yes -i {{file:ssh_key}} -p 2222 developer@test.beichen.example /usr/bin/uptime','running');op.cleanup='等待本次进程组结束'}
    if(state==='reuse-failed')this.recordPrototypeOperation('OP-02','ssh -T -o BatchMode=yes -i {{file:ssh_key}} -p 2222 developer@test.beichen.example /usr/bin/uname','start_failed');
    if(state==='reuse-history')this.recordPrototypeOperation('OP-02','ssh -T -o BatchMode=yes -i {{file:ssh_key}} -p 2222 developer@test.beichen.example /usr/bin/uname');
    if(state==='reuse-unknown')this.recordPrototypeOperation('OP-02','ssh -T -o BatchMode=yes -i {{file:ssh_key}} -p 2222 developer@test.beichen.example /usr/bin/uptime','unknown');
    if(state==='reuse-revoked'){const op=this.recordPrototypeOperation('OP-02','ssh -T -o BatchMode=yes -i {{file:ssh_key}} -p 2222 developer@test.beichen.example /usr/bin/uptime','running');op.cleanup='等待本次进程组结束';this.revokeReusable()}
   }
  }
 }));
 app.init=function(){init.call(this);this.initializeReuse()};return app;
};
