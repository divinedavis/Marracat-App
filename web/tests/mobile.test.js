import { test } from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import Database from 'better-sqlite3';
import { generateKeyPair, SignJWT } from 'jose';
import { mobileRoutes, verifyGoogle } from '../server/mobile.js';
const env = { AUTH_GOOGLE_ID: 'server-client', GOOGLE_IOS_CLIENT_ID: 'ios-client' };
test('Google requires signed identity, correct audience/issuer/client and verified email', async () => {
  const {privateKey,publicKey}=await generateKeyPair('RS256');
  const token=async(overrides={})=>new SignJWT({sub:'person',email:'person@example.test',email_verified:true,azp:'ios-client',...overrides})
    .setProtectedHeader({alg:'RS256'}).setIssuer('https://accounts.google.com').setAudience('server-client').setIssuedAt().setExpirationTime('5m').sign(privateKey);
  assert.equal((await verifyGoogle(await token(),env,publicKey)).id,'google:person');
  for(const change of [{azp:'foreign'},{email_verified:false},{sub:''}])await assert.rejects(()=>token(change).then(t=>verifyGoogle(t,env,publicKey)));
  const bad=await new SignJWT({sub:'person'}).setProtectedHeader({alg:'RS256'}).setIssuer('evil').setAudience('other').setIssuedAt().setExpirationTime('5m').sign(privateKey);
  await assert.rejects(()=>verifyGoogle(bad,env,publicKey));
  await assert.rejects(()=>verifyGoogle('not-a-jwt',env,publicKey));
});
async function fixture(t) {
  const db=new Database(':memory:');db.exec('CREATE TABLE users(id TEXT PRIMARY KEY,name TEXT,email TEXT)');
  const app=express();mobileRoutes(app,db,{env,verify:async value=>{
    if(!['alice','bob'].includes(value))throw new Error('invalid');
    return {id:'google:'+value,name:value,email:value+'@example.test'};
  }});
  const server=app.listen(0,'127.0.0.1');await new Promise(resolve=>server.once('listening',resolve));
  t.after(()=>{server.close();db.close();});
  const base='http://127.0.0.1:'+server.address().port+'/api/mobile/';
  const call=async(path,token,body,method=body?'POST':'GET')=>{
    const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},body:body?JSON.stringify(body):undefined});
    return {status:r.status,data:r.status===204?null:await r.json()};
  };
  const login=async name=>(await call('auth/google',null,{idToken:name})).data.token;
  return {db,call,login};
}
test('account isolation and retries cannot resurrect removed likes or history',async t=>{
  const {call,login,db}=await fixture(t),alice=await login('alice'),bob=await login('bob');
  assert.equal((await call('me',null)).status,401);assert.equal((await call('me','forged')).status,401);
  const ops=[{id:'1',kind:'save',value:'product-a'},{id:'2',kind:'search',value:'bags'}];
  await call('activity',alice,{operations:ops});
  await call('activity',alice,{operations:[{id:'3',kind:'unsave',value:'product-a'},{id:'4',kind:'clearHistory'}]});
  const retry=await call('activity',alice,{operations:ops});
  assert.deepEqual(retry.data.profile.saved,[]);assert.deepEqual(retry.data.profile.recentSearches,[]);
  assert.deepEqual((await call('me',bob)).data.profile.saved,[]);
  assert.notEqual(db.prepare('SELECT hash FROM mobile_sessions LIMIT 1').get().hash,alice);
});
test('personalization opt-out clears and stops history while retaining likes',async t=>{
  const {call,login}=await fixture(t),token=await login('alice');
  const r=await call('activity',token,{operations:[{id:'1',kind:'view',value:'item'},{id:'2',kind:'search',value:'hair'},
    {id:'3',kind:'save',value:'item'},{id:'4',kind:'personalization',enabled:false},{id:'5',kind:'view',value:'other'},{id:'6',kind:'search',value:'bags'}]});
  assert.deepEqual(r.data.profile.recentlyViewed,[]);assert.deepEqual(r.data.profile.recentSearches,[]);
  assert.deepEqual(r.data.profile.saved,['item']);assert.equal(r.data.profile.personalizationEnabled,false);
});
test('invalid batches are atomic and checkout callbacks deduplicate without extra personal data',async t=>{
  const {call,login}=await fixture(t),token=await login('alice');
  assert.equal((await call('activity',token,{operations:[{id:'1',kind:'save',value:'x'},{id:'bad',kind:'save',value:55}]})).status,400);
  assert.deepEqual((await call('me',token)).data.profile.saved,[]);
  const checkout={id:'receipt',brandID:'brand',date:1234,itemCount:1,subtotal:10,productIDs:['x'],orderID:'gid://shopify/Order/1',total:12,currency:'USD',subtotalCurrency:'GBP',billingAddress:'private',status:'delivered',items:[{title:'A real item',quantity:2,address:'private'}]};
  const r=await call('activity',token,{operations:[{id:'2',kind:'checkout',checkout},{id:'3',kind:'checkout',checkout:{...checkout,id:'different'}}]});
  assert.equal(r.data.profile.checkouts[0].subtotalCurrency,'GBP');assert.equal(r.data.profile.checkouts[0].currency,'USD');
  assert.equal((await call('activity',token,{operations:[{id:'invalid-currency',kind:'checkout',checkout:{...checkout,id:'bad-currency',subtotalCurrency:'pounds'}}]})).status,400);
  assert.equal(r.data.profile.checkouts.length,1);assert.equal(r.data.profile.checkouts[0].billingAddress,undefined);assert.equal(r.data.profile.checkouts[0].status,undefined);assert.deepEqual(r.data.profile.checkouts[0].items,[{title:'A real item',quantity:2}]);
});
test('deletion requires matching Google identity and revokes all devices',async t=>{
  const {call,login,db}=await fixture(t),a=await login('alice'),a2=await login('alice'),b=await login('bob');
  const oldGeneration=(await call('me',a)).data.user.generation;
  await call('activity',a,{operations:[{id:'1',kind:'save',value:'x'}]});
  assert.equal((await call('account',a,{idToken:'bob'},'DELETE')).status,403);
  assert.equal((await call('account',a,{idToken:'alice'},'DELETE')).status,204);
  for(const token of [a,a2])assert.equal((await call('me',token)).status,401);
  assert.equal((await call('me',b)).status,200);
  assert.equal(db.prepare('SELECT count(*) n FROM mobile_profiles').get().n,0);
  assert.equal(db.prepare('SELECT count(*) n FROM mobile_operations').get().n,0);
  const fresh=await login('alice');const recreated=(await call('me',fresh)).data;assert.deepEqual(recreated.profile.saved,[]);assert.notEqual(recreated.user.generation,oldGeneration);
});
test('signout affects one session and expiry is enforced',async t=>{
  const {call,login,db}=await fixture(t),a=await login('alice'),b=await login('alice');
  assert.equal((await call('signout',a,{},'POST')).status,204);assert.equal((await call('me',a)).status,401);
  assert.equal((await call('me',b)).status,200);db.prepare('UPDATE mobile_sessions SET expires=0').run();assert.equal((await call('me',b)).status,401);
});
test('folders of saved items: create, add, cover, rename, remove, delete; unsave clears folders; old profiles tolerate no lists',async t=>{
  const {call,login,db}=await fixture(t),alice=await login('alice');
  const ops=[{id:'l1',kind:'listCreate',value:'gifts',name:'  Gifts  '},{id:'l2',kind:'save',value:'p1'},{id:'l3',kind:'listAdd',list:'gifts',value:'p1'},
    {id:'l4',kind:'listAdd',list:'gifts',value:'p2'},{id:'l5',kind:'listCover',list:'gifts',value:'p2'},{id:'l6',kind:'listCover',list:'gifts',value:'not-in-list'}];
  let p=(await call('activity',alice,{operations:ops})).data.profile;
  assert.equal(p.lists.length,1);assert.equal(p.lists[0].name,'Gifts');assert.deepEqual(p.lists[0].items,['p2','p1']);assert.equal(p.lists[0].cover,'p2');
  p=(await call('activity',alice,{operations:[{id:'l7',kind:'listRename',value:'gifts',name:'Holiday gifts'},{id:'l8',kind:'listRemove',list:'gifts',value:'p2'},{id:'l9',kind:'listCover',list:'gifts',value:'photo'}]})).data.profile;
  assert.equal(p.lists[0].name,'Holiday gifts');assert.deepEqual(p.lists[0].items,['p1']);assert.equal(p.lists[0].cover,'photo');
  p=(await call('activity',alice,{operations:[{id:'l10',kind:'unsave',value:'p1'}]})).data.profile;
  assert.deepEqual(p.lists[0].items,[]);
  assert.equal((await call('activity',alice,{operations:[{id:'x',kind:'listCreate',value:'z',name:''}]})).status,400);
  // 2026-11-12: a folder id names a file on the phone; "../" in one walked out of its folder.
  for(const bad of ['../../x','a/b','..','a b','x.jpg'])assert.equal((await call('activity',alice,{operations:[{id:'bad',kind:'listCreate',value:bad,name:'Bad'}]})).status,400,bad);
  assert.equal((await call('activity',alice,{operations:[{id:'ok1',kind:'listCreate',value:'0b9c8c1e-7d1f-4a51-9d5e-2c1f6f0d9a11',name:'Ok'},{id:'ok2',kind:'listDelete',value:'0b9c8c1e-7d1f-4a51-9d5e-2c1f6f0d9a11'}]})).status,200);
  assert.equal((await call('activity',alice,{operations:[{id:'y',kind:'listAdd',list:'z'}]})).status,400);
  p=(await call('activity',alice,{operations:[{id:'l11',kind:'listDelete',value:'gifts'}]})).data.profile;
  assert.deepEqual(p.lists,[]);
  // A profile written before folders existed has no `lists`; the next change must not throw.
  db.prepare("UPDATE mobile_profiles SET data=? WHERE user_id=?").run(JSON.stringify({saved:['old'],recentlyViewed:[],recentSearches:[],checkouts:[],hidden:[],personalizationEnabled:true}),'google:alice');
  p=(await call('activity',alice,{operations:[{id:'l12',kind:'listCreate',value:'later',name:'Later'}]})).data.profile;
  assert.equal(p.lists[0].name,'Later');assert.deepEqual(p.saved,['old']);
});
