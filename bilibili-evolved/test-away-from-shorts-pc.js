// AwayFromShorts PC · 顶栏收敛 —— 自测
// 模拟 Bilibili Evolved 的 loadFeatureCode 沙箱 + customNavbar.items 数据流 + 样式注入
// 用法: node test-away-from-shorts-pc.js
const fs = require('fs')
const path = require('path')
const assert = require('assert')

const CODE = fs.readFileSync(path.join(__dirname, 'away-from-shorts-pc.js'), 'utf8')

/** 按 Bilibili Evolved 的方式把插件代码跑一遍, 返回导出的 plugin 和注入的 <style> */
function loadPlugin(storage) {
  const injected = []
  const fakeDocument = {
    head: {
      appendChild(node) {
        injected.push(node)
      },
    },
    documentElement: {},
    createElement() {
      return { id: '', textContent: '' }
    },
    getElementById() {
      return undefined
    },
  }
  const fakeWindow = {
    document: fakeDocument,
    localStorage: {
      getItem: key => (key in storage ? storage[key] : null),
      setItem: (key, value) => {
        storage[key] = value
      },
      removeItem: key => {
        delete storage[key]
      },
    },
    console,
    setTimeout,
    // 页面里的 window.eval / window.Object 都必须存在, 沙箱的 with(window) 会从 window 上取
    eval,
    Object,
  }
  fakeWindow.window = fakeWindow

  // 与 Bilibili Evolved 的 createCodeSandbox 一致:
  // exports 和代码字符串都通过注入表进入 with(window) 作用域, 再用 eval 执行
  const exportsObj = {}
  const injection = new Map([
    ['exports', exportsObj],
    ['AFS_PLUGIN_CODE_KEY', CODE],
  ])
  const sandbox = new Proxy(Object.create(null), {
    has: () => true,
    get: (_, key) => (injection.has(key) ? injection.get(key) : fakeWindow[key]),
    set: (_, key, value) => {
      if (!injection.has(key)) {
        fakeWindow[key] = value
      }
      return true
    },
  })
  new Function('window', 'with (window) { return eval(AFS_PLUGIN_CODE_KEY) }')(sandbox)

  return { plugin: Object.values(exportsObj)[0], injected }
}

/** 内置顶栏元素（只保留断言需要的那几个） */
function makeNavbarItems() {
  return [
    { name: 'feeds' }, // 动态
    { name: 'ranking' }, // 排行
    { name: 'lives' }, // 直播
    { name: 'bangumi' }, // 番剧
    { name: 'search' }, // 搜索
    { name: 'userInfo' }, // 用户
  ]
}

function runCase(name, storage, expectedRemoved) {
  const { plugin, injected } = loadPlugin(storage)
  assert(plugin, '插件没有导出 (exports.plugin 为空)')
  assert.strictEqual(plugin.name, 'awayFromShortsPC')
  assert.strictEqual(typeof plugin.setup, 'function')

  const providers = []
  plugin.setup({
    addData(key, provider) {
      providers.push({ key, provider })
    },
  })
  assert.strictEqual(providers.length, 1, '应注册 1 个数据 provider')
  assert.strictEqual(providers[0].key, 'customNavbar.items', 'provider 的 key 不对')

  const items = makeNavbarItems()
  providers[0].provider(items)
  const left = items.map(item => item.name)

  assert.strictEqual(injected.length, 1, '应注入且只注入 1 个 <style>')
  const css = injected[0].textContent

  expectedRemoved.forEach(removed => {
    assert(!left.includes(removed), `${name}: ${removed} 应被删掉, 实际剩下 ${left}`)
    assert(css.includes(`.custom-navbar-item[data-name="${removed}"]`), `${name}: CSS 缺 ${removed}`)
    assert(
      css.includes(`.navbar-sort-item[data-name="${removed}"]`),
      `${name}: CSS 缺布局设置里的 ${removed}`,
    )
  })
  assert(left.includes('bangumi') && left.includes('userInfo'), `${name}: 误删了其他元素 ${left}`)
  assert(css.includes('t.bilibili.com'), `${name}: 缺原版顶栏动态入口的规则`)

  const hidesWholeBar = css.includes('\n.custom-navbar,\n')
  assert.strictEqual(hidesWholeBar, name === 'none', `${name}: 整个顶栏的隐藏状态不对`)

  console.log(`PASS ${name}: 删掉 [${expectedRemoved.join(', ')}], 保留 [${left.join(', ')}]`)
}

runCase('feed(默认)', {}, ['feeds'])
runCase('strict', { 'afs-topbar-mode': 'strict' }, ['feeds', 'ranking', 'lives'])
runCase('none', { 'afs-topbar-mode': 'none' }, ['feeds', 'ranking', 'lives'])
runCase('非法值回退默认', { 'afs-topbar-mode': 'oops' }, ['feeds'])

// provider 被喂进奇怪的东西时不能炸
{
  const { plugin } = loadPlugin({})
  let provider
  plugin.setup({ addData: (key, fn) => (provider = fn) })
  provider(undefined)
  provider({})
  provider([])
  console.log('PASS 异常输入不抛错')
}

console.log('ALL PASS')
