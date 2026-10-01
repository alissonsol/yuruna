const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict'), path = require('node:path');
const context = { window: {} }; vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../../test/extension/download-agent-service/server/internal/httpsrv/web/assets/sort.js'),'utf8'), context);
const S = context.window.YSort;
const rows = Array.from({length:10000},(_,i)=>({hostType:'kvm', imageKey:'img'+(i%317), arch:i%2?'arm64':'amd64',variant:'stable',state:['fresh','failed','unknown',null][i%4],currentBytes:[NaN,Infinity,null,0,123][i%5],lastVerifiedAt:i%2?'2026-01-01':'invalid',generation:'gen'+i,sourceUrl:i%3?'HTTP://HOST/':'',checksumVerdict:'ok'}));
let keys=0;const original=S.key;S.key=(...a)=>{keys++;return original(...a)};
for(const col of S.columns) for(const dir of [-1,1]) {const expected=rows.slice().sort(S.compare(col,dir));keys=0; const actual=S.sort(rows,col,dir);assert.deepEqual(Array.from(actual),expected);assert.equal(keys,rows.length);}
console.log('Sort: 14 column/direction comparisons match; exactly one key calculation per row.');
