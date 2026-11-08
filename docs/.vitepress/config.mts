import path from 'node:path'
import { withMermaid } from 'vitepress-plugin-mermaid'
import { sidebar } from './sidebar.mts'

const repository = 'https://github.com/daidr/ziggurat'
const branch = 'dev'

// Links from the docs to source files (examples/, src/, tests/ ...) or to
// data kept beside the pages resolve to the repository on GitHub, so pages
// can keep the relative links that also work when read on GitHub.
function repositoryLink(href: string, page: string): string | null {
  if (/^[a-z][a-z0-9+.-]*:/i.test(href) || href.startsWith('#') || href.startsWith('/')) return null
  const [target, hash = ''] = href.split('#')
  if (target === '') return null
  const resolved = path.posix.normalize(path.posix.join('docs', path.posix.dirname(page), target))
  const outside = !resolved.startsWith('docs/')
  const data = resolved.startsWith('docs/benchmarks') || /\.(zig|json|html|ts|js|c|h|ps1|sh|txt)$/.test(resolved)
  if (!outside && !data) return null
  const kind = target.endsWith('/') || !path.posix.extname(resolved) ? 'tree' : 'blob'
  return `${repository}/${kind}/${branch}/${resolved.replace(/\/$/, '')}${hash ? `#${hash}` : ''}`
}

export default withMermaid({
  lang: 'zh-CN',
  title: 'Ziggurat',
  description: '以 Zig 为中心的桌面应用框架：原生 UI 或网页前端，一份 Zig 代码。',
  cleanUrls: true,
  lastUpdated: true,
  srcExclude: ['node_modules/**', 'benchmarks/**', 'README.md'],
  head: [['meta', { name: 'theme-color', content: '#c2410c' }]],
  markdown: {
    config(md) {
      const render = md.renderer.rules.link_open ?? ((tokens, index, options, _env, self) => self.renderToken(tokens, index, options))
      md.renderer.rules.link_open = (tokens, index, options, env, self) => {
        const token = tokens[index]
        const href = token.attrGet('href')
        const rewritten = href && repositoryLink(href, env.relativePath ?? '')
        if (rewritten) token.attrSet('href', rewritten)
        return render(tokens, index, options, env, self)
      }
    },
  },
  themeConfig: {
    nav: [
      { text: '指南', link: '/guide/introduction', activeMatch: '^/guide/' },
      { text: '原生 UI', link: '/ui/', activeMatch: '^/ui/' },
      { text: '插件', link: '/plugins' },
      { text: '参考', link: '/reference/', activeMatch: '^/reference/' },
      { text: '示例', link: '/examples' },
    ],
    sidebar,
    outline: { level: [2, 3], label: '本页内容' },
    socialLinks: [{ icon: 'github', link: repository }],
    editLink: { pattern: `${repository}/edit/${branch}/docs/:path`, text: '在 GitHub 上编辑此页' },
    search: {
      provider: 'local',
      options: {
        translations: {
          button: { buttonText: '搜索文档', buttonAriaLabel: '搜索文档' },
          modal: {
            noResultsText: '没有找到结果',
            resetButtonTitle: '清除查询',
            footer: { selectText: '选择', navigateText: '切换', closeText: '关闭' },
          },
        },
      },
    },
    docFooter: { prev: '上一页', next: '下一页' },
    lastUpdated: { text: '最后更新' },
    returnToTopLabel: '回到顶部',
    sidebarMenuLabel: '菜单',
    darkModeSwitchLabel: '外观',
    lightModeSwitchTitle: '切换到浅色模式',
    darkModeSwitchTitle: '切换到深色模式',
    footer: { message: '以 MIT 许可证发布' },
  },
  mermaid: {},
})
