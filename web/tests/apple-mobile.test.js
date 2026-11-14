import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import express from 'express';
import Database from 'better-sqlite3';
import { generateKeyPair, SignJWT, exportPKCS8, jwtVerify } from 'jose';
import { appleMobileAuth, verifyAppleToken } from '../server/apple-mobile.js';
import { mobileRoutes } from '../server/mobile.js';
const env = { APPLE_IOS_CLIENT_ID:'com.example.app', APPLE_TEAM_ID:'TEAM', APPLE_KEY_ID:'KEY' };
const nonce='a'.repeat(64);
async function signer() {
  const keys=await generateKeyPair('RS256');
  return {keys, sign: (overrides={})=>new SignJWT({sub:'person',nonce,email:'private@privaterelay.appleid.com',email_verified:'true',...overrides})
    .setProtectedHeader({alg:'RS256'}).setIssuer('https://appleid.apple.com').setAudience(env.APPLE_IOS_CLIENT_ID).setIssuedAt().setExpirationTime('5m').sign(keys.privateKey)};
}
test('Apple identity requires correct signature, audience, issuer, freshness and one-use nonce; relay email works',async()=>{
  const {keys,sign}=await signer();
  assert.equal((await verifyAppleToken(await sign(),nonce,env,keys.publicKey)).id,'apple:person');
  for(const changes of [{nonce:'wrong'},{sub:''},{email_verified:false}])await assert.rejects(()=>sign(changes).then(token=>verifyAppleToken(token,nonce,env,keys.publicKey)));
  const other=await generateKeyPair('RS256');
  const validToken=await sign();await assert.rejects(()=>verifyAppleToken(validToken,nonce,env,other.publicKey));
  for (const attrs of [{iss:'https://example.test',aud:env.APPLE_IOS_CLIENT_ID},{iss:'https://appleid.apple.com',aud:'other'}]) {
    const bad=await new SignJWT({sub:'person',nonce,...attrs}).setProtectedHeader({alg:'RS256'}).setIssuedAt().setExpirationTime('5m').sign(keys.privateKey);
    await assert.rejects(()=>verifyAppleToken(bad,nonce,env,keys.publicKey));
  }
  const expired=await new SignJWT({sub:'person',nonce}).setProtectedHeader({alg:'RS256'}).setIssuer('https://appleid.apple.com').setAudience(env.APPLE_IOS_CLIENT_ID).setIssuedAt(1).setExpirationTime(2).sign(keys.privateKey);
  await assert.rejects(()=>verifyAppleToken(expired,nonce,env,keys.publicKey));
  async function noEmail() {const t=await sign({email:undefined,email_verified:undefined});return verifyAppleToken(t,nonce,env,keys.publicKey);}
  assert.equal((await noEmail()).email,null);
});

test('Apple exchanges the code with a freshly signed client secret and verifies returned identity before revocation',async t=>{
  const directory=mkdtempSync(join(tmpdir(),'marracat-apple-test-'));t.after(()=>rmSync(directory,{recursive:true,force:true}));
  const clientKeys=await generateKeyPair('ES256',{extractable:true}),apple=await signer();
  const path=join(directory,'test.p8');writeFileSync(path,await exportPKCS8(clientKeys.privateKey),{mode:0o600});
  const configured={...env,APPLE_PRIVATE_KEY_PATH:path};const requests=[];
  let exchangedPerson='person';
  const auth=appleMobileAuth(configured,{keys:apple.keys.publicKey,fetcher:async(url,options)=>{
    assert.equal(options.redirect,'error');const params=options.body;
    const {payload}=await jwtVerify(params.get('client_secret'),clientKeys.publicKey,{issuer:'TEAM',audience:'https://appleid.apple.com'});
    assert.equal(payload.sub,env.APPLE_IOS_CLIENT_ID);assert.ok(payload.exp-payload.iat<=300);
    requests.push({url,params});
    return new Response(url.endsWith('/token')?JSON.stringify({id_token:await apple.sign({sub:exchangedPerson}),refresh_token:'refresh-secret'}):'',{status:200});
  }});
  const grant=await auth.authorize({idToken:await apple.sign(),authorizationCode:'one-use-code',name:' A Name ',email:'forged@example.test'},nonce);
  assert.equal(grant.user.email,'private@privaterelay.appleid.com');assert.equal(grant.user.name,'A Name');
  await auth.revoke(grant.refreshToken);assert.equal(requests[1].params.get('token_type_hint'),'refresh_token');assert.equal(requests[1].params.get('token'),'refresh-secret');
  exchangedPerson='attacker';await assert.rejects(()=>apple.sign().then(idToken=>auth.authorize({idToken,authorizationCode:'other-code'},nonce)));
  const broken=appleMobileAuth(configured,{keys:apple.keys.publicKey,fetcher:async()=>new Response('',{status:400})});
  await assert.rejects(()=>apple.sign().then(idToken=>broken.authorize({idToken,authorizationCode:'invalid-code'},nonce)));
});

async function fixture(t) {
  const db=new Database(':memory:');db.exec('CREATE TABLE users(id TEXT PRIMARY KEY,name TEXT,email TEXT)');
  let revokeFails=false;const revoked=[];
  const app=express();mobileRoutes(app,db,{env,verify:async()=>({id:'google:alice',name:'Google',email:'same@example.test'}),apple:{
    configured:()=>true,
    authorize:async(body,expected)=>{
      if(body.nonce!==expected || !['alice','bob'].includes(body.person))throw Error('invalid');
      return {user:{id:'apple:'+body.person,name:body.name??null,email:body.email??null},refreshToken:'grant:'+body.person};
    },
    revoke:async token=>{if(revokeFails)throw Error('offline');revoked.push(token);}
  }});
  const server=app.listen(0,'127.0.0.1');await new Promise(resolve=>server.once('listening',resolve));t.after(()=>{server.close();db.close();});
  const call=async(path,token,body,method=body?'POST':'GET')=>{
    const r=await fetch('http://127.0.0.1:'+server.address().port+'/api/mobile/'+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},body:body?JSON.stringify(body):undefined});
    return {status:r.status,data:r.status===204?null:await r.json()};
  };
  const challenge=async()=> (await call('auth/apple/challenge',null,{})).data;
  const login=async(extra={})=>call('auth/apple',null,{...await challenge(),person:'alice',...extra});
  return {db,call,challenge,login,revoked,setRevokeFailure:v=>{revokeFails=v;}};
}
test('Apple challenges cannot be replayed, expired or reused after a failed attempt',async t=>{
  const {call,challenge,db}=await fixture(t);
  const c=await challenge();assert.equal((await call('auth/apple',null,{...c,person:'alice'})).status,200);
  assert.equal((await call('auth/apple',null,{...c,person:'alice'})).status,401);
  const old=await challenge();db.prepare('UPDATE mobile_apple_challenges SET expires=0').run();assert.equal((await call('auth/apple',null,{...old,person:'alice'})).status,401);
  const failed=await challenge();assert.equal((await call('auth/apple',null,{...failed,nonce:'wrong',person:'alice'})).status,401);
  assert.equal((await call('auth/apple',null,{...failed,person:'alice'})).status,401);
});
// One account per person (owner, 2026-10-02): until then this test pinned the
// opposite, and the owner's Apple sign-in hid their Google account's orders.
test('Apple with the same verified email opens the Google account, and deleting it needs Apple',async t=>{
  const {call,login,challenge,revoked}=await fixture(t);
  const google=(await call('auth/google',null,{idToken:'google'})).data.token;
  await call('activity',google,{operations:[{id:'g',kind:'save',value:'google-item'}]});
  const a=(await login({name:'Apple Name',email:'Same@Example.test'})).data;
  assert.equal(a.user.id,'google:alice');assert.deepEqual(a.profile.saved,['google-item']);
  assert.equal(a.user.signedInWith,'apple:alice');assert.equal(a.user.confirmWith,'apple');
  assert.equal(a.user.name,'Google','the account keeps its own name and email');assert.equal(a.user.email,'same@example.test');
  // Apple sends the email only sometimes; the link holds without it.
  const again=(await login()).data;assert.equal(again.user.id,'google:alice');
  assert.equal((await call('me',again.token)).data.user.signedInWith,'apple:alice');
  // Someone else's Apple ID with another address gets their own account.
  const bob=(await call('auth/apple',null,{...await challenge(),person:'bob',email:'bob@example.test'})).data;
  assert.equal(bob.user.id,'apple:bob');assert.deepEqual(bob.profile.saved,[]);
  // Signed in with Google, deleting still goes through Apple, so its access is revoked.
  assert.equal((await call('me',google)).data.user.confirmWith,'apple');
  assert.equal((await call('account',google,{idToken:'google'},'DELETE')).status,401);
  assert.equal((await call('account',google,{...await challenge(),person:'bob'},'DELETE')).status,403);
  assert.equal((await call('account',google,{...await challenge(),person:'alice'},'DELETE')).status,204);
  assert.deepEqual(revoked,['grant:alice']);
  for(const token of [google,a.token,again.token])assert.equal((await call('me',token)).status,401);
  const fresh=(await login({email:'same@example.test'})).data;
  assert.equal(fresh.user.id,'apple:alice','a deleted account leaves no link behind');
});
test('a private relay address never links, and accounts that already exist stay apart',async t=>{
  const {db,call,login}=await fixture(t);
  db.prepare("INSERT INTO users(id,name,email) VALUES('google:relay',NULL,'x@privaterelay.appleid.com')").run();
  assert.equal((await login({email:'x@privaterelay.appleid.com'})).data.user.id,'apple:alice');
  // An Apple account made before linking keeps opening itself.
  const google=(await call('auth/google',null,{idToken:'google'})).data;
  assert.equal(google.user.id,'google:alice');
  assert.equal((await login()).data.user.id,'apple:alice');
});
test('Apple deletion verifies matching provider identity, revokes access, then removes every device session',async t=>{
  const {call,login,challenge,revoked,setRevokeFailure}=await fixture(t);
  const a=(await login()).data.token,a2=(await login()).data.token;
  await call('activity',a,{operations:[{id:'a',kind:'save',value:'apple-item'}]});
  assert.equal((await call('account',a,{...await challenge(),person:'bob'},'DELETE')).status,403);assert.deepEqual(revoked,[]);
  setRevokeFailure(true);assert.equal((await call('account',a,{...await challenge(),person:'alice'},'DELETE')).status,503);
  assert.deepEqual((await call('me',a)).data.profile.saved,['apple-item']);
  setRevokeFailure(false);assert.equal((await call('account',a,{...await challenge(),person:'alice'},'DELETE')).status,204);
  assert.deepEqual(revoked,['grant:alice']);for(const token of [a,a2])assert.equal((await call('me',token)).status,401);
});
