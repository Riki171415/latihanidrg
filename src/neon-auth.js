import {createNeonIdentity,authData,identityMessage} from './neon-identity.js';
const $=id=>document.getElementById(id);
const config=JSON.parse($('neon-config').textContent);
const auth=createNeonIdentity(config.authBaseURL);
let register=true,busy=false;
function setBusy(value){busy=value;for(const element of document.querySelectorAll('input,button'))element.disabled=value;}
function message(text,error=false){$('status').textContent=text;$('status').classList.toggle('incorrect',error);}
function renderUser(user){
  $('identity-form').hidden=!!user;$('switch').hidden=!!user;$('logout').hidden=!user;$('current-user').hidden=!user;
  $('current-user').textContent=user?[user.name,user.email].filter(Boolean).join(' Â· '):'';
  $('title').textContent=user?'Akun Anda':register?'Daftar akun':'Masuk';
  $('name-field').hidden=!register;$('name').required=register;
  $('password').autocomplete=register?'new-password':'current-password';
  $('submit').textContent=register?'Daftar':'Masuk';$('switch').textContent=register?'Sudah punya akun? Masuk':'Belum punya akun? Daftar';
}
async function readCurrent(){const data=authData(await auth.getSession({query:{disableCookieCache:true}}));renderUser(data?.user);return data?.user;}
$('switch').addEventListener('click',()=>{if(busy)return;register=!register;message('');renderUser(null);});
$('identity-form').addEventListener('submit',async event=>{
  event.preventDefault();if(busy)return;setBusy(true);message(register?'Mendaftarkan akunâ€¦':'Memeriksa akunâ€¦');
  try{
    const credentials={email:$('email').value.trim(),password:$('password').value};
    if(register)authData(await auth.signUp.email({...credentials,name:$('name').value.trim()}));else authData(await auth.signIn.email(credentials));
    const user=await readCurrent();message(user?'Anda berhasil masuk.':'Pendaftaran diterima, tetapi sesi belum aktif. Periksa pengaturan akun Neon.');
  }catch(error){message(identityMessage(error),true);}
  finally{$('password').value='';setBusy(false);}
});
$('logout').addEventListener('click',async()=>{
  if(busy)return;setBusy(true);
  try{authData(await auth.signOut());await readCurrent();message('Anda sudah keluar.');}
  catch(error){message(identityMessage(error),true);}finally{setBusy(false);}
});
setBusy(true);readCurrent().catch(()=>message('Akun belum dapat dimuat. Periksa koneksi lalu coba masuk.',true)).finally(()=>setBusy(false));
