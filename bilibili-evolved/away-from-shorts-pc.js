/**
 * AwayFromShorts PC · 顶栏收敛
 * ------------------------------------------------------------------
 * 一个 Bilibili Evolved 用户插件：
 *   1. 把「动态」（以及可选的「排行」「直播」）从 B站顶栏里彻底拿掉；
 *   2. 连「顶栏布局设置 → 元素呈现」里的条目也一起拿掉，
 *      所以就算手滑去点眼睛图标，也点不回来；
 *   3. 想更狠一点：整个顶栏都不显示（`none` 模式）。
 *
 * 安装：Bilibili Evolved 设置面板 → 插件 → 「浏览」选择本文件
 *       （或把本文件的 URL 粘到插件页的输入框里）→ 刷新页面。
 * 模式：默认 `feed`（只删「动态」）。想换模式，在 B站页面控制台执行：
 *       localStorage.setItem('afs-topbar-mode', 'strict')  // 动态/排行/直播
 *       localStorage.setItem('afs-topbar-mode', 'none')    // 整个顶栏都不要
 *       localStorage.setItem('afs-topbar-mode', 'feed')    // 改回只删动态
 *       然后刷新页面。改动随时可用 localStorage.removeItem('afs-topbar-mode') 还原。
 * 卸载：设置面板 → 插件 → 移除本插件 → 刷新页面。
 * ------------------------------------------------------------------
 */
;(function () {
  'use strict'

  var VERSION = '1.0.0'
  var STORAGE_KEY = 'afs-topbar-mode'
  var DEFAULT_MODE = 'feed'

  /**
   * 模式定义。
   * navbarItems 里的名字对应 Bilibili Evolved 自定义顶栏的元素 name：
   *   feeds=动态  ranking=排行  lives=直播  bangumi=番剧  music=音频
   *   games=游戏中心  shop=会员购  manga=漫画  match=赛事
   *   creations=创作中心  subscriptions=订阅  watchlater=稍后再看
   */
  var MODES = {
    feed: {
      label: '只删「动态」',
      navbarItems: ['feeds'],
    },
    strict: {
      label: '删「动态 / 排行 / 直播」',
      navbarItems: ['feeds', 'ranking', 'lives'],
    },
    none: {
      label: '整个顶栏都不显示',
      navbarItems: ['feeds', 'ranking', 'lives'],
    },
  }

  function readMode() {
    try {
      var stored = localStorage.getItem(STORAGE_KEY)
      if (stored && Object.prototype.hasOwnProperty.call(MODES, stored)) {
        return stored
      }
    } catch (e) {
      /* 无痕模式等拿不到 localStorage 时用默认值 */
    }
    return DEFAULT_MODE
  }

  var mode = readMode()
  var removedNames = MODES[mode].navbarItems.slice()

  // ---- 样式 ----------------------------------------------------------

  var NATIVE_RULES = [
    '/* 原版顶栏（没开自定义顶栏时）的「动态」入口 */',
    '.bili-header a[href*="t.bilibili.com"],',
    '.international-header a[href*="t.bilibili.com"],',
    '#biliMainHeader a[href*="t.bilibili.com"],',
    '.z-top-container a[href*="t.bilibili.com"],',
    'li.nav-item[report-id="playpage_dynamic"] {',
    '  display: none !important;',
    '}',
  ].join('\n')

  var NONE_RULES = [
    '/* none 模式：整个自定义顶栏（含它的布局设置弹窗）都不显示 */',
    '.custom-navbar,',
    '.custom-navbar-settings,',
    'body.custom-navbar-loading::after {',
    '  display: none !important;',
    '}',
    '/* 顶栏拿掉后别再给它留 50px 的空位 */',
    '.bili-header,',
    '.international-header {',
    '  min-height: 0 !important;',
    '}',
  ].join('\n')

  function buildCss() {
    var selectors = []
    removedNames.forEach(function (name) {
      selectors.push('.custom-navbar .custom-navbar-item[data-name="' + name + '"]')
      // 顶栏布局设置 →「元素呈现」里的同名条目也藏掉（兜底，正常会被数据层直接删掉）
      selectors.push('.custom-navbar-settings .navbar-sort-item[data-name="' + name + '"]')
    })
    var parts = [
      '/* AwayFromShorts PC · 顶栏收敛 v' + VERSION + ' (mode: ' + mode + ') */',
    ]
    if (selectors.length > 0) {
      parts.push(selectors.join(',\n') + ' {\n  display: none !important;\n}')
    }
    parts.push(NATIVE_RULES)
    if (mode === 'none') {
      parts.push(NONE_RULES)
    }
    return parts.join('\n\n')
  }

  var STYLE_ID = 'afs-topbar-style'

  function injectStyle(css) {
    var parent = document.head || document.documentElement
    if (!parent) {
      setTimeout(function () {
        injectStyle(css)
      }, 50)
      return
    }
    var old = document.getElementById(STYLE_ID)
    if (old && old.parentNode) {
      old.parentNode.removeChild(old)
    }
    var style = document.createElement('style')
    style.id = STYLE_ID
    style.textContent = css
    parent.appendChild(style)
  }

  // ---- 数据层：让元素从「顶栏布局设置」里也直接消失 --------------------

  /**
   * Bilibili Evolved 的自定义顶栏在挂载时通过
   *   registerAndGetData('customNavbar.items', getBuiltInItems())
   * 收集元素。插件在 setup 里注册的 provider 会在这时拿到全部元素，
   * 我们原地删掉目标项，于是顶栏和布局设置里都不再有它们。
   */
  function filterNavbarItems(items) {
    if (!items || typeof items.length !== 'number') {
      return
    }
    for (var i = items.length - 1; i >= 0; i--) {
      var item = items[i]
      if (item && removedNames.indexOf(item.name) !== -1) {
        items.splice(i, 1)
      }
    }
  }

  function setup(params) {
    injectStyle(buildCss())
    if (params && typeof params.addData === 'function') {
      params.addData('customNavbar.items', filterNavbarItems)
    }
  }

  // ---- 导出（Bilibili Evolved 用沙箱里的 exports 取第一个导出值） ----

  var plugin = {
    name: 'awayFromShortsPC',
    displayName: 'AwayFromShorts PC · 顶栏收敛',
    author: {
      name: 'AwayFromShorts',
      link: 'https://github.com/sdgfdii/AwayFromShorts',
    },
    description:
      '把「动态」等入口从自定义顶栏和「顶栏布局设置 → 元素呈现」里彻底移除；可选把整个顶栏一起拿掉。(mode: ' +
      mode +
      ')',
    setup: setup,
  }

  if (typeof exports !== 'undefined' && exports) {
    exports.plugin = plugin
  } else if (typeof module !== 'undefined' && module && module.exports) {
    module.exports = plugin
  }
})()
