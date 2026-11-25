const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const html = fs.readFileSync(path.join(__dirname, '../src/web/study.html'), 'utf8');
for (const m of html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/g)) new vm.Script(m[1]);
let source = html.match(/<script id="appScript">([\s\S]*?)<\/script>/)[1];
source = source.replace('if(document.readyState === "loading")', `
refreshAll = function(){}; renderSync = function(){}; toast = function(){};
getDB = function(){return testDB;};
globalThis.app = {S:S,ui:ui,readAll:readAll,archive:sdkDeleteGoal,restore:restoreGoal,
  suggest:suggestOf,props:goalProps,backup:backupPayload,week:weekStats,
  renderDeleted:renderRecentlyDeleted,
  setup:setupCheckinPage,tabs:TABS,
  checkin:doCheckin,saveGoal:saveGoal,overdue:isOverdue};
if(document.readyState === "loading")`);
const tables = {
  '0bGK9KsEEiWn1pc5rpkt0x': [{id:'row-g',目标ID:'g',目标名称:'Test',单位:'题',总量:100,已完成量:0,每日默认量:7,截止日:'2099-01-01'}],
  'cfTvN9M6VSQCFyrGJrWM9Z': [{id:'row-l',记录ID:'l',目标ID:'g',日期:'2026-01-01',完成量:4,时间戳:1}],
  'cSUu6XxaPEVUnz6FXFkPZ3': [], 'v3qalVwAq3UxCQv7MGWK44': []
};
/* 极简 DOM 桩：el/mount 需要 createElement/appendChild，才能验证「最近删除」真的渲染出恢复按钮 */
function fakeNode(tag){
  const attrs = {};
  const n = {
    nodeType: 1, tagName: tag, childNodes: [], textContent: '', style: {}, value: '',
    disabled: false, parentNode: null,
    classList: {add(){},remove(){},toggle(){},contains(){return false;}},
    appendChild(c){ n.childNodes.push(c); c.parentNode = n; return c; },
    removeChild(c){ const i = n.childNodes.indexOf(c); if(i >= 0) n.childNodes.splice(i, 1); return c; },
    get firstChild(){ return n.childNodes[0] || null; },
    setAttribute(k, v){ attrs[k] = String(v); },
    getAttribute(k){ return Object.prototype.hasOwnProperty.call(attrs, k) ? attrs[k] : null; },
    removeAttribute(k){ delete attrs[k]; },
    querySelector(){ return null; },
    insertBefore(c,b){ const i=n.childNodes.indexOf(b); n.childNodes.splice(i < 0 ? 0 : i,0,c); c.parentNode=n; return c; },
    addEventListener(){}, focus(){}, select(){}, click(){},
  };
  return n;
}
const nodes = {};
const node = id => nodes[id] ||= fakeNode(id);
const walk = n => [n].concat(...(n.childNodes || []).map(walk));
const restoreButtons = id => walk(node('recentlyDeletedList'))
  .filter(n => n.getAttribute && n.getAttribute('data-restore') === id).length;
let failUpdate = false, adds = 0;
const db = {
  query: async o => ({results: structuredClone(tables[o.databaseId])}),
  updateRecord: async o => {
    if(failUpdate) throw Error('disk write failed');
    const row=tables[o.databaseId].find(r=>r.id===o.recordId);
    for(const [k,v] of Object.entries(o.properties)) row[k]=Object.values(v)[0];
    return row;
  },
  addRecord: async o => {
    adds++;
    const row={id:'new-'+adds};
    for(const [k,v] of Object.entries(o.properties)) row[k]=Object.values(v)[0];
    tables[o.databaseId].push(row);
    return row;
  },
  deleteRecord: async o => {tables[o.databaseId]=tables[o.databaseId].filter(r=>r.id!==o.recordId);}
};
const ctx=vm.createContext({testDB:db,console:{log(){}},window:{},
  document:{readyState:'loading',addEventListener(){},getElementById:node,
    createElement:fakeNode,createTextNode:t=>({nodeType:3,textContent:String(t)})},
  localStorage:{setItem(){},getItem(){return null;}},setTimeout,clearTimeout,Date,Promise});
vm.runInContext(source,ctx);
const a=ctx.app;
const flush=()=>new Promise(resolve=>setImmediate(resolve));
(async()=>{
  assert.equal(a.tabs.map(t=>t.id).join(','),'today,weekly,mine');
  a.setup();
  assert.equal(node('panel-board').parentNode,node('panel-today'),'management belongs inside check-in page');
  assert.equal(walk(node('panel-board')).filter(n=>n.getAttribute && n.getAttribute('data-template')!==null).length,6,'six phone templates rendered');
  await a.readAll();
  assert.equal(a.S.goals.length,1);
  assert.equal(a.suggest(a.S.goals[0]),7);
  assert.equal(a.props(a.S.goals[0])['每日默认量'].number,7);
  await a.archive(a.S.goals[0]);
  assert.equal(a.S.goals.length,0);
  assert.equal(a.S.logs.length,0);
  assert.equal(a.S.archived.length,1);
  assert.equal(a.S.archivedLogs.length,1);
  assert.equal(tables['cfTvN9M6VSQCFyrGJrWM9Z'].length,1,'archive preserves stored logs');
  assert.equal(a.backup().goals[0].archived,true);
  assert.equal(a.backup().logs.length,1);
  a.renderDeleted();
  assert.equal(restoreButtons('g'),1,'归档后「我的 → 最近删除」必须出现恢复按钮');
  assert.match(node('recentlyDeletedHint').textContent,/1 个已删除目标/);
  a.restore('g'); await flush();
  assert.equal(a.S.goals.length,1);
  assert.equal(a.S.logs.length,1);
  assert.equal(a.S.goals[0].daily,7);
  a.renderDeleted();
  assert.equal(restoreButtons('g'),0,'恢复后最近删除里不再有它');
  // 删除＝归档，但历史数字不能跟着变：周报必须继续统计归档目标的记录
  await a.archive(a.S.goals[0]);
  assert.equal(a.S.logs.length,0);
  assert.equal(a.week('2026-01-01','2026-01-07').per['g'].sum,4,'archived goal keeps its weekly total');
  a.restore('g'); await flush();
  assert.equal(a.S.goals.length,1);
  assert.equal(a.S.logs.length,1);
  const g=a.S.goals[0];
  g.deadline='';g.daily=0;assert.equal(a.overdue(g),false);
  assert.equal(a.suggest(g),4,'no deadline uses 30-day automatic plan');
  g.daily=150;assert.equal(a.suggest(g),150,'phone custom default is used unchanged');
  g.daily=7;
  const before=adds;
  a.checkin('g',true);a.checkin('g',true);await flush();
  assert.equal(adds-before,1,'rapid double submit adds exactly one log');
  a.checkin('g',true);await flush();assert.equal(adds-before,2,'a later intentional extra log is allowed');
  a.ui.editing='g';
  Object.entries({fName:'Edited',fUnit:'题',fTotal:'100',fDaily:'9',fDeadline:'',fObstacle:'',fPlan:''}).forEach(([id,value])=>node(id).value=value);
  failUpdate=true;a.saveGoal();await flush();
  assert.equal(g.name,'Test','failed writes do not change displayed goal');
  assert.equal(g.daily,7);assert.equal(node('modalSave').disabled,false);
  failUpdate=false;a.saveGoal();await flush();assert.equal(g.name,'Edited');assert.equal(g.daily,9);
  console.log('PASS: 最近删除渲染恢复按钮 / 恢复后移除、备份、归档仍计入周报、默认量、不限期、重复提交、保存失败与成功');
})().catch(e=>{console.error(e);process.exitCode=1;});
