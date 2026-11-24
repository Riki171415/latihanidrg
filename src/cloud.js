import {createClient} from '@supabase/supabase-js';
const config=JSON.parse(document.getElementById('app-config').textContent);
export const client=createClient(config.supabaseUrl,config.supabasePublishableKey);
export async function requireDirectSignup(){
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
export async function rpc(name,args={}){
  const {data,error}=await client.rpc(name,args).abortSignal(AbortSignal.timeout(15000));
  if(error)throw error;
  return data;
}
export async function readRpc(name,args={}){
  let lastError;
  // A bounded retry applies only to read-only RPCs. Never replay a save or
  // submission: the first request could already have committed its changes.
  for(let attempt=0;attempt<2;attempt++){
    const result=await client.rpc(name,args).abortSignal(AbortSignal.timeout(12000));
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
      if(error.name==='AuthSessionMissingError'||error.status===401||error.status===403)return null;
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
  return [503,504,520].includes(status)||error?.code==='PGRST003'||error?.name==='TimeoutError'||error?.name==='AbortError'||/timed out acquiring|timeout|abort|failed to fetch|network/i.test(error?.message??'');
}
export function attemptFromRow(row){
  return {id:row.id,index:row.case_index,question:row.question_index,answers:row.answers,finished:!!row.submitted_at,
    submittedAt:row.submitted_at,correctCount:row.correct_count,totalCount:row.total_count,version:row.version,
    editCount:row.edit_count??0,revision:row.revision,contentRevision:row.revision};
}
export function friendly(error){
  const message=error?.message??String(error);
  if(/^PGRST00[0-3]$/.test(error?.code??'')||error?.status===504||/timed out acquiring connection/i.test(message))return 'Layanan data Supabase sedang tidak tersedia. Tunggu sebentar lalu coba lagi.';
  if(/Invalid login credentials/i.test(message))return 'Email atau password tidak sesuai.';
  if(/Email not confirmed/i.test(message))return 'Akun belum aktif untuk masuk langsung. Hubungi pengelola pelatihan.';
  if(/User already registered|already been registered/i.test(message))return 'Email sudah terdaftar. Silakan masuk menggunakan akun tersebut.';
  if(/Database error saving new user|duplicate key/i.test(message))return 'Pendaftaran belum berhasil. Periksa isian; username mungkin sudah digunakan.';
  if(/rate limit|too many/i.test(message))return 'Terlalu banyak permintaan. Coba lagi beberapa saat.';
  if(/schema cache|does not exist|could not find.*function/i.test(message))return 'Layanan akun belum selesai disiapkan. Hubungi pengelola pelatihan.';
  if(/fetch|network/i.test(message))return 'Koneksi terputus. Periksa koneksi internet lalu coba lagi.';
  return message;
}
