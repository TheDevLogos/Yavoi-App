export const attentionCategories = { drivers: 'Conductores', documents: 'Documentos', payments: 'Cuotas y liquidaciones', finance: 'Contabilidad', safety: 'Reportes y seguridad', ratings: 'Calificaciones', rates: 'Tarifas', communications: 'Comunicaciones', rewards: 'Recompensas' };
export function isAttentionActive(item) {
  return Boolean(item.unread || (item.actionable && !item.attended));
}
export function filterAttention(items, { category = '', status = 'active', priority = '', search = '' } = {}) {
  const query = search.trim().toLocaleLowerCase('es-MX');
  return items.filter(item => (!category || item.category === category)
    && (!priority || item.priority === Number(priority))
    && (status === 'all' || (status === 'unread' ? item.unread : status === 'pending' ? item.actionable && isAttentionActive(item) : isAttentionActive(item)))
    && (!query || `${item.title} ${item.body}`.toLocaleLowerCase('es-MX').includes(query)));
}
export function attentionTarget(hash) {
  const [view, kind, id] = hash.replace(/^#/, '').split('/');
  if (!id || !/^[a-z0-9-]+$/i.test(id)) return null;
  const targets = { driver: ['fleet','data-driver-card'], fee: ['fleet','data-weekly-fee-card'], settlement: ['payments','data-settlement-id'], report: ['help','data-report-card'], event: ['audit','data-audit-id'], fiscal: ['finance','data-finance-driver'], reward: ['marketing','data-reward-review'], bank: ['payments','data-operations-bank'], communications: ['marketing','data-operations-communications'] };
  const match = targets[kind];
  return match?.[0] === view ? `[${match[1]}="${id}"]` : null;
}
