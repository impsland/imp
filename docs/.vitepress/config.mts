import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'Imp',
  description: 'Documentation for Imp: the apps, the Den, the Hop, the CLI and the browser extension.',
  cleanUrls: true,
  themeConfig: {
    nav: [
      { text: 'Guide', link: '/guide/getting-started' },
      { text: 'Connecting', link: '/connecting/phone' },
      { text: 'Sharing', link: '/sharing/setups' },
      { text: 'Development', link: '/development/building' },
      { text: 'Design', link: '/design/' },
      { text: 'UX', link: '/ux/' },
      { text: 'Architecture', link: '/architecture/' },
    ],
    sidebar: [
      {
        text: 'Start',
        items: [
          { text: 'Overview', link: '/' },
          { text: 'Getting started', link: '/guide/getting-started' },
          { text: 'Glossary', link: '/glossary' },
        ],
      },
      {
        text: 'Guide',
        items: [
          { text: 'Features', link: '/guide/features' },
          { text: 'Services (models)', link: '/guide/services' },
          { text: 'Privacy', link: '/guide/privacy' },
          { text: 'Automation (imp:// links)', link: '/guide/automation' },
          { text: 'Games on the iPhone', link: '/guide/games' },
        ],
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
        items: [
          { text: 'Imps on other devices', link: '/connecting/phone' },
          { text: 'Imp Link (protocol)', link: '/connecting/link' },
        ],
      },
      {
        text: 'Sharing',
        items: [
          { text: 'Sharing setups', link: '/sharing/setups' },
          { text: 'The Den', link: '/sharing/den' },
          { text: 'Kit format', link: '/sharing/kits' },
        ],
      },
      {
        text: 'Apps',
        items: [
          { text: 'Terminal app (imp)', link: '/apps/cli' },
          { text: 'Using the terminal chat', link: '/apps/cli-chat' },
          { text: 'Commands in the chat', link: '/apps/cli-commands' },
          { text: 'Sub-agents', link: '/apps/cli-agents' },
          { text: 'Testing', link: '/apps/testing' },
          { text: 'Releasing the Mac app', link: '/apps/macos-release' },
        ],
      },
      {
        text: 'Development',
        items: [{ text: 'Building from source', link: '/development/building' }],
      },
      {
        text: 'Design',
        items: [
          { text: 'Design', link: '/design/' },
          { text: 'The room never leaves', link: '/design/room' },
        ],
      },
      {
        text: 'UX specification',
        items: [
          { text: 'Overview', link: '/ux/' },
          { text: 'Main screen', link: '/ux/main-screen' },
          { text: 'Imps', link: '/ux/imps' },
          { text: 'Imp Settings', link: '/ux/imp-settings' },
          { text: 'All Imps settings', link: '/ux/all-imps-settings' },
          { text: 'Devices', link: '/ux/devices' },
          { text: 'First run', link: '/ux/first-run' },
          { text: 'States', link: '/ux/states' },
          { text: 'Motion', link: '/ux/motion' },
          { text: 'Accessibility', link: '/ux/accessibility' },
          { text: 'Platforms', link: '/ux/platforms' },
          { text: 'Parity', link: '/ux/parity' },
          { text: 'All words', link: '/ux/strings' },
        ],
      },
      {
        text: 'Glossary',
        items: [{ text: 'Glossary', link: '/glossary' }],
      },
      {
        text: 'Architecture',
        items: [
          { text: 'Layers and layout', link: '/architecture/' },
          { text: 'How the apps reach the core', link: '/architecture/core' },
          { text: 'Threat model of Imp Link', link: '/architecture/threat-model' },
        ],
      },
    ],
    search: { provider: 'local' },
    outline: 'deep',
  },
})
