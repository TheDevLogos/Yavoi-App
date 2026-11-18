import { db, escapeHtml as e } from './client.js';
import { attentionCategories, filterAttention, attentionTarget, isAttentionActive } from './operations-attention-domain.js';
import './operations-attention.css';
let items = [], userId = null, timer = null, channel = null, loading = null, generation = 0, initialized = false;
let filters = { category: '', status: 'active', priority: '', search: '' };
let renderListener = null;
const labels = ['', 'Urgente', 'Por atender', 'Informativo'];
const formatDate = value => value ? new Date(value).toLocaleString('es-MX', { dateStyle: 'medium', timeStyle: 'short' }) : '';
async function call(payload = {}) {
  const { data, error } = await db.rpc('yavoi_operations_attention', { payload });
  if (error) throw error;
  return data;
}
function update() {
  const unread = items.filter(item => item.unread).length;
  document.querySelectorAll('[data-ops-alert-count]').forEach(node => { node.textContent = unread > 99 ? '99+' : String(unread); node.hidden = !unread; });
  document.querySelectorAll('[data-ops-alert-link]').forEach(node => node.setAttribute('aria-label', `Alertas administrativas: ${unread} sin leer`));
  renderListener?.();
}
export function stopOperationsAttention() {
  generation++; userId = null; initialized = false; items = []; loading = null;
  clearInterval(timer); timer = null;
  if (channel) db.removeChannel(channel);
  channel = null; renderListener = null;
}
export async function refreshOperationsAttention({ notify = true } = {}) {
  if (!userId) return;
  if (loading) return loading;
  const epoch = generation;
  loading = (async () => {
    const data = await call();
    if (epoch !== generation) return;
    const old = new Set(items.map(item => `${item.id}:${item.version}`));
    const fresh = data.items.filter(item => item.unread && !old.has(`${item.id}:${item.version}`));
    items = data.items;
    if (notify && initialized && fresh.length && 'Notification' in window && Notification.permission === 'granted') {
      try {
        const item = fresh[0];
        const notice = new Notification(fresh.length > 1 ? `${fresh.length} avisos nuevos de Operaciones` : item.title, { body: item.body, icon: '/icons/yavoi-192.png', tag: 'yavoi-operations-attention' });
        notice.onclick = () => {
          window.focus();
          location.hash = fresh.length > 1 ? 'alerts' : item.href.slice(1);
          if (fresh.length === 1) {
            call({ action: 'read', id: item.id, version: item.version }).then(result => {
              if (epoch === generation) { items = result.items; update(); }
            }).catch(() => {});
          }
          notice.close();
        };
      } catch { /* The persistent inbox remains available when desktop notices are unsupported. */ }
    }
    initialized = true; update();
  })().finally(() => { if (epoch === generation) loading = null; });
  return loading;
}
export function startOperationsAttention(id) {
  if (userId === id) { update(); return; }
  stopOperationsAttention(); userId = id;
  refreshOperationsAttention({ notify: false }).catch(() => {});
  timer = setInterval(() => { if (!document.hidden) refreshOperationsAttention().catch(() => {}); }, 30000);
  channel = db.channel(`operations-attention-${id}`);
  channel.on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'operations_attention_signal' }, () => refreshOperationsAttention().catch(() => {})).subscribe();
}
export function attentionSummaryMarkup() {
  return `<a class="ops-attention-summary panel" href="#alerts"><span>Centro de pendientes</span><strong>Revisar alertas administrativas</strong><small>Conductores · cuotas · contabilidad · seguridad <b data-ops-alert-count hidden></b></small></a>`;
}
export async function mountOperationsAttention(host) {
  renderListener = null;
  host.innerHTML = '<section class="panel" role="status">Consultando los pendientes de Operaciones…</section>';
  let errorText = '';
  const render = () => {
    if (!host.isConnected) { if(renderListener === render) renderListener=null; return; }
    // Background refreshes must not replace an unfinished search or focused control.
    if(host.contains(document.activeElement) && document.activeElement.matches('input,select')) return;
    const visible = filterAttention(items, filters);
    host.innerHTML = `<section class="panel ops-attention"><div class="row between wrap"><div><h2>Pendientes y novedades</h2><p>Los informativos leídos se ocultan. Los pendientes se retiran al resolverse o al revisar un cambio registrado en el asunto.</p></div><div class="row wrap"><button class="btn secondary" data-ops-alert-refresh>Actualizar</button><button class="btn secondary" data-ops-alert-permission>Activar avisos del navegador</button></div></div><div class="ops-alert-kpis"><span><b>${items.filter(i=>i.actionable && isAttentionActive(i)).length}</b> pendientes</span><span><b>${items.filter(i=>i.priority===1 && isAttentionActive(i)).length}</b> urgentes</span><span><b>${items.filter(i=>i.unread).length}</b> sin leer</span></div>${errorText ? `<p role="alert">${e(errorText)}</p>` : ''}<form class="ops-alert-filters"><label>Área<select name="category"><option value="">Todas las áreas</option>${Object.entries(attentionCategories).map(([key,label])=>`<option value="${key}" ${filters.category===key?'selected':''}>${label}</option>`).join('')}</select></label><label>Vista<select name="status">${[['active','Activos (automático)'],['pending','Pendientes activos'],['unread','Sin leer'],['all','Todos los avisos']].map(([key,label])=>`<option value="${key}" ${filters.status===key?'selected':''}>${label}</option>`).join('')}</select></label><label>Prioridad<select name="priority"><option value="">Todas las prioridades</option>${labels.slice(1).map((label,index)=>`<option value="${index+1}" ${String(filters.priority)===String(index+1)?'selected':''}>${label}</option>`).join('')}</select></label><label>Buscar<input name="search" type="search" value="${e(filters.search)}" placeholder="Conductor, periodo o asunto"></label><button class="btn secondary" type="submit">Filtrar</button></form><div class="ops-alert-list">${visible.map(item=>`<article class="ops-alert priority-${item.priority} ${item.unread?'unread':''}"><div class="ops-alert-copy"><div class="row wrap"><span class="badge ${item.priority===1?'pending':'neutral'}">${labels[item.priority]}</span><small>${e(attentionCategories[item.category])}${item.unread?' · Nuevo':''}</small></div><h3>${e(item.title)}</h3><p>${e(item.body)}</p><small>${item.due_at ? `Plazo registrado: ${e(formatDate(item.due_at))}` : `Registrado: ${e(formatDate(item.occurred_at))}`}</small></div><div class="ops-alert-actions"><a class="btn" data-ops-alert-open="${e(item.id)}" href="${e(item.href)}">${item.actionable?'Atender':'Ver detalle'}</a>${item.unread?`<button class="link" data-ops-alert-read="${e(item.id)}">Marcar leído</button>`:`<small>${item.attended?'Cambio revisado':'Leído'}</small>`}</div></article>`).join('') || '<div class="empty"><h3>Sin avisos en esta vista</h3><p>Prueba otra área o consulta todos los avisos.</p></div>'}</div></section>`;
    host.querySelector('form').onsubmit = event => { event.preventDefault(); filters=Object.fromEntries(new FormData(event.currentTarget)); document.activeElement?.blur(); render(); };
    host.querySelector('[data-ops-alert-refresh]').onclick = async event => {
      event.currentTarget.disabled = true;
      try { await refreshOperationsAttention({ notify: false }); errorText=''; } catch(error) { errorText=`No pudimos actualizar: ${error.message}`; } render();
    };
    host.querySelector('[data-ops-alert-permission]').onclick = async event => {
      if (!('Notification' in window)) { errorText='Este navegador no admite avisos de escritorio.'; render(); return; }
      try { const permission=await Notification.requestPermission(); event.target.textContent=permission==='granted'?'Avisos activados':'Permiso no concedido'; } catch { errorText='Activa los avisos desde los ajustes del navegador.'; render(); }
    };
    host.querySelectorAll('[data-ops-alert-open],[data-ops-alert-read]').forEach(button => button.onclick = () => {
      const item=items.find(i=>i.id === (button.dataset.opsAlertOpen || button.dataset.opsAlertRead));
      if(!item?.unread) return;
      const epoch=generation;
      call({ action:'read',id:item.id,version:item.version }).then(data => { if(epoch!==generation) return; items=data.items; update(); }).catch(error => { errorText=`No se pudo guardar la lectura: ${error.message}`; if(host.isConnected) render(); });
    });
  };
  try { await refreshOperationsAttention({ notify:false }); } catch(error) { errorText=`No pudimos cargar los avisos: ${error.message}`; }
  if(!host.isConnected) return;
  renderListener=render; render();
}
export function focusOperationsAttentionTarget() {
  const hash=location.hash;
  const selector=attentionTarget(hash);
  if(!selector) return;
  let attempts=0;
  const find=()=> {
    if(location.hash!==hash) return;
    const node=document.querySelector(selector);
    if(!node) { if(++attempts<30) setTimeout(find,200); return; }
    let parent=node;
    while(parent) { if(parent.tagName==='DETAILS') parent.open=true; parent=parent.parentElement; }
    node.classList.add('ops-alert-focus'); node.scrollIntoView({ behavior:'smooth',block:'center' });
  };
  find();
}
document.addEventListener('visibilitychange',()=> { if(!document.hidden && userId) refreshOperationsAttention().catch(()=>{}); });
