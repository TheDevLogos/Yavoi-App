import {createClient} from '@supabase/supabase-js';
import {SUPABASE_URL,SUPABASE_KEY} from './config.js';
export const db=createClient(SUPABASE_URL,SUPABASE_KEY,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true,flowType:'pkce',storageKey:'yavoi-auth-v2'}});
export async function rpc(command,payload={}){const {data,error}=await db.rpc('yavoi',{command,payload});if(error)throw new Error(error.message);if(data?.error)throw new Error(data.error);return data;}
export const money=cents=>new Intl.NumberFormat('es-MX',{style:'currency',currency:'MXN'}).format((cents||0)/100);
export const escapeHtml=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
