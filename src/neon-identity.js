import {createAuthClient} from '@neon/auth';
export function createNeonIdentity(baseURL){
  let url;
  try{url=new URL(baseURL);}catch{throw new Error('URL Neon Auth belum valid.');}
  if(url.protocol!=='https:'||!url.hostname.endsWith('.neon.tech')||url.username||url.password||url.search||url.hash)throw new Error('URL Neon Auth belum valid. Gunakan NEON_AUTH_BASE_URL dari neon deploy.');
  if(url.pathname.includes('/rest/'))throw new Error('URL Data API tidak dapat digunakan sebagai URL Neon Auth.');
  return createAuthClient(url.href.replace(/\/$/,''));
}
export function authData(result){
  if(result.error){const error=new Error(result.error.message||'Layanan akun belum tersedia.');error.code=result.error.code;throw error;}
  return result.data;
}

export function identityMessage(error){
  const value=[error?.code,error?.message].filter(Boolean).join(' ');
  if(/INVALID_EMAIL_OR_PASSWORD|invalid email or password/i.test(value))return 'Email atau password tidak sesuai.';
  if(/USER_ALREADY_EXISTS|already exists|already registered/i.test(value))return 'Email sudah terdaftar. Silakan masuk menggunakan akun tersebut.';
  if(/EMAIL_NOT_VERIFIED|email.*not verified/i.test(value))return 'Akun belum aktif untuk masuk langsung. Hubungi pengelola pelatihan.';
  if(/PASSWORD_TOO_SHORT|password.*short/i.test(value))return 'Password terlalu pendek. Gunakan sedikitnya 10 karakter.';
  if(/TOO_MANY|rate limit/i.test(value))return 'Terlalu banyak percobaan. Tunggu sebentar lalu coba lagi.';
  return 'Layanan akun belum dapat dihubungi. Coba kembali beberapa saat.';
}
