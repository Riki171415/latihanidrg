import {createClient} from '@supabase/supabase-js';
import {createInternalNeonAuth} from '@neon/auth';
import {SupabaseAuthAdapter} from '@neon/auth/vanilla/adapters';
const config=JSON.parse(document.getElementById('app-config').textContent);
const queryBackend=new URLSearchParams(globalThis.location?.search??'').get('backend');
const canUseNeon=Boolean(config.neonAuthUrl&&config.neonDataApiUrl);
export const provider=((queryBackend==='neon'||config.provider==='neon')&&canUseNeon)?'neon':'supabase';
const neonAuth=provider==='neon'?createInternalNeonAuth(config.neonAuthUrl,{adapter:SupabaseAuthAdapter()}):null;
const supabaseClient=provider==='supabase'?createClient(config.supabaseUrl,config.supabasePublishableKey):null;
export const client=provider==='neon'?{auth:neonAuth.adapter}:supabaseClient;
export async function requireDirectSignup(){
  if(provider==='neon')return;
  let response;
  try{
    response=await fetch(config.supabaseUrl+'/auth/v1/settings',{
      headers:{apikey:config.supabasePublishableKey},signal:AbortSignal.timeout(12000)
    });
  }catch{throw new Error('Koneksi ke layanan pendaftaran terputus. Coba lagi beberapa saat.');}
  if(!response.ok)throw new Error('Layanan pendaftaran belum tersedia. Coba lagi beberapa saat.');
  const settings=await response.json();
  if(settings.mailer_autoconfirm!==true)throw new Error('Pendaftaran langsung belum diaktifkan. Hubungi pengelola pelatihan.');
}
async function callRpc(name,args,timeoutMs){
  if(provider==='neon'){
    const token=await neonAuth.getJWTToken();
    if(!token)throw Object.assign(new Error('Silakan masuk terlebih dahulu.'),{code:'42501',status:401});
    const response=await fetch(config.neonDataApiUrl.replace(/\/$/,'')+'/rpc/'+encodeURIComponent(name),{
      method:'POST',
      headers:{'Content-Type':'application/json',Authorization:'Bearer '+token},
      body:JSON.stringify(args),
      signal:AbortSignal.timeout(timeoutMs)
    });
    const text=await response.text();
    let payload=null;
    if(text){try{payload=JSON.parse(text);}catch{}}
    if(!response.ok){
      const err=Object.assign(new Error(payload?.message||'Permintaan data gagal ('+response.status+').'),payload??{},{status:response.status});
      return {data:null,error:err,status:response.status};
    }
    return {data:payload,error:null,status:response.status};
  }
  return client.rpc(name,args).abortSignal(AbortSignal.timeout(timeoutMs));
}
export async function rpc(name,args={}){
  const {data,error}=await callRpc(name,args,15000);
  if(error)throw error;
  return data;
}
export async function readRpc(name,args={}){
  let lastError;
  // A bounded retry applies only to read-only RPCs. Never replay a save or
  // submission: the first request could already have committed its changes.
  for(let attempt=0;attempt<2;attempt++){
    const result=await callRpc(name,args,12000);
    if(!result.error)return result.data;
    lastError=result.error;
    if(!isTemporaryAccountError(lastError,result.status))throw lastError;
    if(attempt===0)await new Promise(resolve=>setTimeout(resolve,1000+Math.random()*500));
    else if(lastError&&typeof lastError==='object'&&lastError.status===undefined&&result.status){
      lastError=Object.assign(new Error(lastError.message||'Layanan sedang sibuk.'),lastError,{status:result.status});
    }
  }
  throw lastError;
}
export async function loadAccount(knownUser=null){
  let user=knownUser;
  if(!user){
    const {data,error}=await client.auth.getUser();
    if(error){
      if(error.name==='AuthSessionMissingError'||error.code==='session_not_found'||error.code==='session_expired'||error.status===401||error.status===403)return null;
      throw error;
    }
    user=data.user;
  }
  if(!user)return null;
  try{
    const data=await readRpc('idrg_load_account');
    return {user,...data};
  }catch(error){
    if(isTemporaryAccountError(error,error?.status)){
      throw new Error('Login berhasil, tetapi data akun belum dapat dimuat karena layanan sedang sibuk. Gunakan tombol Coba muat akun; Anda tidak perlu mengganti password.');
    }
    throw error;
  }
}
function isTemporaryAccountError(error,status){
  return [502,503,504,520,521,522,523,524].includes(status)||/^PGRST00[0-3]$/.test(error?.code??'')||error?.name==='TimeoutError'||error?.name==='AbortError'||/timed out acquiring|timeout|abort|failed to fetch|network/i.test(error?.message??'');
}
export function attemptFromRow(row){
  return {id:row.id,index:row.case_index,question:row.question_index,answers:row.answers,finished:!!row.submitted_at,
    submittedAt:row.submitted_at,correctCount:row.correct_count,totalCount:row.total_count,version:row.version,
    editCount:row.edit_count??0,revision:row.revision,contentRevision:row.revision};
}
export function friendly(error){
  const message=error?.message??String(error);
  const code=error?.code??'';
  if(/^PGRST00[0-3]$/.test(code)||[502,503,504,520,521,522,523,524].includes(error?.status)||/timed out acquiring connection/i.test(message))return 'Layanan data sedang tidak tersedia. Tunggu sebentar lalu coba lagi.';
  if(code==='invalid_credentials'||/Invalid login credentials|INVALID_EMAIL_OR_PASSWORD|invalid email or password/i.test(message))return 'Email atau password tidak sesuai.';
  if(code==='email_not_confirmed'||/Email not confirmed|EMAIL_NOT_VERIFIED/i.test(message))return 'Akun belum aktif untuk masuk langsung. Hubungi pengelola pelatihan.';
  if(code==='user_already_exists'||code==='email_exists'||/User already registered|already been registered|USER_ALREADY_EXISTS|already exists/i.test(message))return 'Email sudah terdaftar. Silakan masuk menggunakan akun tersebut.';
  if(code==='weak_password'||/PASSWORD_TOO_SHORT|password.*short/i.test(message))return 'Password terlalu pendek. Gunakan sedikitnya 8–10 karakter.';
  if(/Database error saving new user|duplicate key/i.test(message))return 'Pendaftaran belum berhasil. Periksa isian; username mungkin sudah digunakan.';
  if(code==='over_request_rate_limit'||/rate limit|too many|TOO_MANY/i.test(message))return 'Terlalu banyak permintaan. Coba lagi beberapa saat.';
  if(/schema cache|does not exist|could not find.*function/i.test(message))return 'Layanan akun belum selesai disiapkan. Hubungi pengelola pelatihan.';
  if(/fetch|network/i.test(message))return 'Koneksi terputus. Periksa koneksi internet lalu coba lagi.';
  return message;
}
