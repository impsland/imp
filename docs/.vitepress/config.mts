import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'Imp',
  description: 'Documentation for Imp: the apps, the Den, the Hop, the CLI and the browser extension.',
  cleanUrls: true,
  themeConfig: {
    nav: [
      { text: 'Guide', link: '/' },
      { text: 'Concepts', link: '/concepts/models' },
      { text: 'Connecting', link: '/connecting/link' },
      { text: 'Sharing', link: '/sharing/kits' },
      { text: 'Design', link: '/design/' },
    ],
    sidebar: [
      {
        text: 'Start',
        items: [{ text: 'Overview', link: '/' }],
      },
      {
        text: 'Concepts',
        items: [
          { text: 'Core models', link: '/concepts/models' },
          { text: 'Chat bubble', link: '/concepts/bubble' },
          { text: 'Transfer by shaking', link: '/concepts/transfer' },
        ],
      },
      {
        text: 'Connecting devices',
        items: [{ text: 'Imp Link 2', link: '/connecting/link' }],
      },
      {
        text: 'Sharing',
        items: [{ text: 'Kit format', link: '/sharing/kits' }],
      },
      {
        text: 'Design',
        items: [{ text: 'Design', link: '/design/' }],
      },
    ],
    search: { provider: 'local' },
    outline: 'deep',
  },
})
