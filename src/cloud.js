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
  const {data,error}=await client.rpc(name,args);
  if(error)throw error;
  return data;
}
export async function loadAccount(){
  const {data:{user},error}=await client.auth.getUser();
  if(error||!user)return null;
  const {data:person,error:profileError}=await client.from('idrg_profiles').select('*').eq('user_id',user.id).single();
  if(profileError&&profileError.code!=='PGRST116')throw profileError;
  const {data:attempts,error:attemptError}=await client.from('idrg_attempts').select('*').eq('user_id',user.id).order('created_at',{ascending:true});
  if(attemptError)throw attemptError;
  return {user,person,attempts,admin:await rpc('idrg_is_admin')};
}
export function attemptFromRow(row){
  return {id:row.id,index:row.case_index,question:row.question_index,answers:row.answers,finished:!!row.submitted_at,
    submittedAt:row.submitted_at,correctCount:row.correct_count,totalCount:row.total_count,version:row.version,
    editCount:row.edit_count??0,revision:row.revision,contentRevision:row.revision};
}
export function friendly(error){
  const message=error?.message??String(error);
  if(/Invalid login credentials/i.test(message))return 'Email atau password tidak sesuai.';
  if(/Email not confirmed/i.test(message))return 'Akun belum aktif untuk masuk langsung. Hubungi pengelola pelatihan.';
  if(/User already registered|already been registered/i.test(message))return 'Email sudah terdaftar. Silakan masuk menggunakan akun tersebut.';
  if(/Database error saving new user|duplicate key/i.test(message))return 'Pendaftaran belum berhasil. Periksa isian; username mungkin sudah digunakan.';
  if(/rate limit|too many/i.test(message))return 'Terlalu banyak permintaan. Coba lagi beberapa saat.';
  if(/schema cache|does not exist|could not find.*function/i.test(message))return 'Layanan akun belum selesai disiapkan. Hubungi pengelola pelatihan.';
  if(/fetch|network/i.test(message))return 'Koneksi terputus. Jawaban belum tersimpan ke server; coba simpan lagi.';
  return message;
}
