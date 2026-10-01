// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync(__dirname+'/../assets/yuruna.core.js','utf8');
const block=source.slice(source.indexOf('  function isPlainBody('),source.indexOf('  // --- REGION: Control proof'));
function api(response){const c={Y:{},has:(o,k)=>Object.prototype.hasOwnProperty.call(o,k),Promise,Error,Object,window:{AbortController,setTimeout,clearTimeout,fetch:()=>response}};vm.runInNewContext(block,c);return c.Y.api;}
test('JSON success and explicit empty success',async()=>{
 assert.equal((await api(Promise.resolve({ok:true,status:200,json:async()=>({id:1})}))('/x')).id,1);
 assert.equal(Object.keys(await api(Promise.resolve({ok:true,status:204,json:async()=>{throw new Error('empty')}}))('/x')).length,0);
});
test('invalid success fails while HTTP errors retain status',async()=>{
 await assert.rejects(api(Promise.resolve({ok:true,status:200,json:async()=>{throw new SyntaxError('truncated')}}))('/x'),/truncated/);
 await assert.rejects(api(Promise.resolve({ok:false,status:502,json:async()=>{throw new SyntaxError('html')}}))('/x'),e=>e.status===502);
});
test('timeout settles even when transport never resolves',async()=>{
 await assert.rejects(api(new Promise(()=>{}))('/x',{timeoutMs:20}),/too long/);
});
