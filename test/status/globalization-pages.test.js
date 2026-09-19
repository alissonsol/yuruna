// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');
const {makeEl, idsIn} = require('../extension/ui-pages.test.js');
const ROOT = path.resolve(__dirname, '../..');
const localeManifest=JSON.parse(fs.readFileSync(path.join(ROOT, 'globalization/locale-manifest.json'),'utf8'));
const deliveredLocales=Object.keys(localeManifest.locales).filter(tag=>['supported','pseudo'].includes(localeManifest.locales[tag].status));
const status = fs.readFileSync(path.join(__dirname, 'yuruna.common.js'), 'utf8');
const statusDoc = {
  overallStatus: 'running', cycleStartUtc: '2026-09-18T12:00:00Z', startedAt: '2026-09-18T12:00:00Z',
  hostname: 'cafe\u0301-茶-😀-عربي-\u2069\u202e<spoof>', host: 'host.ubuntu.kvm', hostId: '426d17ef0b88426b922180dad1a9e921',
  guests: [{guestKey:'guest.ubuntu.server.26', status:'running', vmName:'vm-one', steps:[{name:'New-VM', status:'pass', startedAt:'2026-09-18T12:00:00Z', finishedAt:'2026-09-18T12:01:00Z'}]}],
  history: [], sequences: [{name:'project.smoke', guests:['guest.ubuntu.server.26']}],
  gitCommit:'abcd0123', cycleFolderUrl:'log/000001.2026-09-18.12-00-00.host/'
};
function element(tag) {
  const el=makeEl(tag); el.classList={add(c){if(!el.className.split(' ').includes(c))el.className+=' '+c;},remove(c){el.className=el.className.split(' ').filter(x=>x!==c).join(' ');},toggle(c,on){if(on===undefined)on=!this.contains(c);on?this.add(c):this.remove(c);return on;},contains(c){return el.className.split(' ').includes(c);}};
  el.getBoundingClientRect=()=>({top:0,left:0,right:100,bottom:20,width:100,height:20});
  return el;
}
function runtime(html, locale, resolver) {
  const byId={}; idsIn(html).forEach(id=>byId[id]=element('div'));
  const root=element('html');root.setAttribute('lang',locale);
  const listeners={};const failures=[];
  const box={performance:require('perf_hooks').performance,console:{warn(text){if(/Yuruna i18n/.test(text))failures.push(text);},error(){},log(){}},JSON,Math,Date,Number,Object,Array,RegExp,Promise,isNaN,parseInt,parseFloat,encodeURIComponent,decodeURIComponent,
    setTimeout(fn){return setTimeout(fn,0);},clearTimeout,setInterval(){return 0;},clearInterval(){},addEventListener(){},removeEventListener(){},
    navigator:{userAgent:'baseline'},location:{hostname:'fixture',origin:'https://fixture.test',pathname:'/',search:'?cycle=000001.2026-09-18.12-00-00.426d17ef0b88426b922180dad1a9e921',hash:'',href:''},
    history:{replaceState(){}},localStorage:{getItem(){return null;},setItem(){},removeItem(){}},confirm(){return true;},YurunaMeasureRenders:true,
    document:{readyState:'loading',title:'',hidden:false,activeElement:null,body:element('body'),documentElement:root,
      getElementById(id){return byId[id]||null;},createElement:element,createElementNS(_,name){return element(name);},createTextNode(text){return {nodeType:3,textContent:String(text)};},
      querySelector(selector){if(selector === '#t tbody'){return byId['request-rows'] || (byId['request-rows']=element('tbody'));}return null;},querySelectorAll(){return [];},addEventListener(name,fn){(listeners[name]||(listeners[name]=[])).push(fn);},removeEventListener(){}}
  };
  box.XMLHttpRequest=function(){this.open=(_,url)=>{this.url=url;};this.setRequestHeader=()=>{};this.abort=()=>{};this.send=()=>{
    const answer=resolver(this.url.split('?')[0]);if(answer.error){this.status=503;this.responseText='{"ok":false,"error":"Fixture refused"}';}else{this.status=200;this.responseText=typeof answer.body==='string'?answer.body:JSON.stringify(answer.body);}
    this.statusText=this.status===200?'OK':'Unavailable';this.onload();
  };};
  box.window=box;box.globalThis=box;vm.createContext(box);vm.runInContext('Intl=undefined;String.prototype.normalize=undefined;',box);
  return {box,byId,failures,boot(){box.document.readyState='complete';(listeners.DOMContentLoaded||[]).forEach(fn=>fn());}};
}
function loadCatalog(box,domain,locale){vm.runInContext(fs.readFileSync(path.join(ROOT,'globalization/generated/browser',locale+'.'+domain+'.js'),'utf8'),box);}
function statusResponse(page,state,url){
  if(state==='error' && !/caching-proxy-service|host-network/.test(url))return {error:true};
  if(url==='runtime/status.json')return {body:state==='empty'?{}:statusDoc};
  if(url==='control/test-config')return {body:{language:'auto',logLevel:'Information',testCycle:{cycleDelaySeconds:300},guestSequence:['guest.ubuntu.server.26']}};
  if(url==='control/guest-folders')return {body:['guest.ubuntu.server.26']};
  if(url==='control/perf-aggregates')return {body:{generatedAtUtc:'2026-09-18T12:00:00Z',sequences:state==='empty'?{}:{'project.smoke':[{cycleStartedAtUtc:'2026-09-18T12:00:00Z',durationMs:1000,stepCount:1,steps:[{name:'Setup',durationMs:1000}]}]}}};
  if(url==='control/host-diagnostic')return {body:state==='empty'?'':'cafe\u0301 茶 😀 عربي <external detail>'};
  if(url==='control/runtime-env')return {body:{}};
  if(url==='control/runner-status')return {body:{running:true}};
  return {body:''};
}
const settle=()=>new Promise(resolve=>setTimeout(resolve,0));
async function checkStatus(){let checked=0;
  for(const locale of deliveredLocales)for(const page of ['index','config','performance','diagnostics','share-cycle'])for(const state of ['data','empty','error']){
    const html=fs.readFileSync(path.join(__dirname,page+'.html'),'utf8');const env=runtime(html,locale,url=>statusResponse(page,state,url));
    vm.runInContext(status,env.box,{filename:'yuruna.common.js'});if(locale!=='en-US')loadCatalog(env.box,'status',locale);env.boot();
    for(let i=0;i<25;i++)await settle();
    assert.deepStrictEqual(env.failures,[],page+'/'+locale+'/'+state+' catalog fallback');
    assert.strictEqual(env.box.YurunaI18n.locale(),locale);assert.strictEqual(env.box.document.documentElement.getAttribute('dir'),localeManifest.locales[locale].direction);
    const marker=env.box.YurunaFirstUsable;
    assert.ok(marker && marker.page==='test/status/'+page+'.html',page+'/'+locale+'/'+state+' did not finish actual page rendering: '+JSON.stringify(marker));
    const want=page==='share-cycle'?'static':state==='empty'&&page==='config'?'data':state;
    assert.strictEqual(marker.state,want,page+'/'+locale+'/'+state+' wrong renderer state');
    if(page==='index'&&state==='data')assert.ok(env.byId['sequence-list'].innerHTML.includes('project.smoke'));
    checked++;
  }
  console.log('PASS: '+checked+' status page/locale/state renders with fetch, Intl and normalize unavailable');
}
async function checkGenerated(){let checked=0;
 for(const domain of ['cache','parser']){
  const service=domain==='cache'?'caching-proxy-service':'caching-proxy-parser-service';const source=fs.readFileSync(path.join(ROOT,'test/extension',service,domain==='cache'?'ui.go':'parse.go'),'utf8');const html=/const indexHTML = `([\s\S]*?)`/.exec(source)[1];
  const registry=fs.readFileSync(path.join(ROOT,'test/extension',service,'internal/catalog/registry.go'),'utf8');const kernel=JSON.parse(/^const BrowserKernel = (".*")$/m.exec(registry)[1]);const scripts=Array.from(html.matchAll(/<script>([\s\S]*?)<\/script>/g)).map(m=>m[1]);
  for(const locale of deliveredLocales)for(const state of ['data','empty','error']){
   const env=runtime(html,locale,()=>({body:{}}));vm.runInContext(kernel,env.box);if(locale!=='en-US'){loadCatalog(env.box,'status',locale);loadCatalog(env.box,domain,locale);}env.box.YurunaI18n.init(env.box.document);
   const adapter=fs.readFileSync(path.join(ROOT,'test/extension',service,'requestadapter.go'),'utf8');vm.runInContext(/const requestAdapterScript = `([\s\S]*?)`/.exec(adapter)[1],env.box);
   env.box.yurunaRequest=()=>state==='error'?Promise.reject(new Error('Fixture refused')):Promise.resolve(domain==='parser'?(state==='empty'?[]:[{ts:1724284800,client_ip:'茶',method:'GET',status:'TCP_HIT/200',bytes:1024,url:'https://example.test/😀',hierarchy:'DIRECT',mime:'text/plain'}]):{ok:true,mode:'local',squid:{reachable:true},switches:{offline:false,noUpstream:false},registry:{reachable:true,repositories:3},pool:{}});
   scripts.forEach(js=>vm.runInContext(js,env.box));env.boot();for(let i=0;i<15;i++)await settle();
   assert.deepStrictEqual(env.failures,[],domain+'/'+locale+'/'+state+' catalog fallback');
   const marker=env.box.YurunaFirstUsable; const wanted=state==='error'?'error':(domain==='parser'&&state==='empty'?'empty':'data');
   assert.ok(marker && marker.page===domain+'/index' && marker.state===wanted,domain+'/'+locale+'/'+state+' wrong actual readiness marker: '+JSON.stringify(marker));
   const error=env.byId.error||env.byId.err;
   if(state==='error')assert.ok(error && error.textContent.length > 0,domain+' error state was not rendered');
   else assert.ok(env.box.YurunaRenderMeasurements && env.box.YurunaRenderMeasurements.samples.length,domain+' data render not measured');
   checked++;
  }
 }
 console.log('PASS: '+checked+' generated page/locale/state renders');
}
const which=process.argv[2]||'all';Promise.resolve().then(()=>which==='generated'?null:checkStatus()).then(()=>which==='status'?null:checkGenerated()).catch(error=>{console.error(error.stack||error);process.exit(1);});
