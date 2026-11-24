// Explicit real-service verification, never run by npm test/build.
// The email owner must authorize this signup. Never print credentials or sessions.
import {randomBytes} from 'node:crypto';
import assert from 'node:assert/strict';
import {createNeonIdentity,authData} from '../src/neon-identity.js';
const baseURL=process.env.NEON_AUTH_BASE_URL;
const email=process.env.NEON_TEST_EMAIL;
if(!baseURL||!email)throw new Error('NEON_AUTH_BASE_URL dan NEON_TEST_EMAIL diperlukan.');
const origin=new URL(baseURL).origin,cookies=new Map(),nativeFetch=globalThis.fetch;
globalThis.fetch=async(input,init={})=>{
  const target=new URL(typeof input==='string'?input:input instanceof URL?input.href:input.url);
  if(target.origin!==origin)throw new Error('Permintaan uji di luar Neon Auth diblokir.');
  const headers=new Headers(input instanceof Request?input.headers:undefined);
  new Headers(init.headers).forEach((value,key)=>headers.set(key,value));
  headers.set('Origin',process.env.NEON_TEST_ORIGIN||'https://latihanidrg.netlify.app');
  if(cookies.size)headers.set('Cookie',[...cookies].map(([key,value])=>key+'='+value).join('; '));
  const response=await nativeFetch(input,{...init,headers});
  for(const entry of response.headers.getSetCookie()){
    const pair=entry.split(';',1)[0],separator=pair.indexOf('=');
    const key=pair.slice(0,separator),value=pair.slice(separator+1);
    if(!value||/max-age=0/i.test(entry))cookies.delete(key);else cookies.set(key,value);
  }
  return response;
};
const password=randomBytes(30).toString('base64url')+'!aA9';
let auth=createNeonIdentity(baseURL),created=false;
const current=async()=>authData(await auth.getSession({query:{disableCookieCache:true}}));
try{
  assert.equal((await current())?.user??null,null,'anonymous session must be empty');
  const signup=authData(await auth.signUp.email({email,password,name:process.env.NEON_TEST_NAME||'Riki Permana Putra'}));
  created=!!signup?.user;
  assert(signup?.user?.id,'signup must return a real user');
  let session=await current();assert.equal(session?.user?.id,signup.user.id);assert.equal(session.user.email.toLowerCase(),email.toLowerCase());
  console.log('PASS: real signup and current user read back.');
  auth=createNeonIdentity(baseURL);session=await current();assert.equal(session?.user?.id,signup.user.id);
  console.log('PASS: session restored by a fresh SDK client.');
  authData(await auth.signOut());assert.equal((await current())?.user??null,null);
  authData(await auth.signIn.email({email,password}));assert.equal((await current())?.user?.id,signup.user.id);
  console.log('PASS: sign out, anonymous denial, and password sign in.');
} catch(error){
  // SDK exceptions may include request details. Never emit the raw error object.
  console.error(created?'FAIL: user created, but session verification did not complete.':'FAIL: signup not completed; inspect Neon Auth settings and whether email is already registered.');
  process.exitCode=1;
}finally{
  if(created)try{await auth.signOut();}catch{}
  cookies.clear();globalThis.fetch=nativeFetch;
}
