import {createClient} from '@supabase/supabase-js';
import {SUPABASE_URL,SUPABASE_KEY} from './config.js';
export const db=createClient(SUPABASE_URL,SUPABASE_KEY,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true,flowType:'pkce',storageKey:'yavoi-auth-v2'}});
export async function authProviderSettings(){
  const response=await fetch(SUPABASE_URL+'/auth/v1/settings',{headers:{apikey:SUPABASE_KEY},signal:AbortSignal.timeout(5000)});
  if(!response.ok)throw new Error('No pudimos consultar los accesos disponibles.');
  const settings=await response.json();
  return {google:!!settings.external?.google,azure:!!settings.external?.azure,apple:!!settings.external?.apple};
}
export async function rpc(command,payload={}){const {data,error}=await db.rpc('yavoi',{command,payload});if(error)throw new Error(error.message);if(data?.error)throw new Error(data.error);return data;}
export const money=cents=>new Intl.NumberFormat('es-MX',{style:'currency',currency:'MXN'}).format((cents||0)/100);
export const escapeHtml=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
