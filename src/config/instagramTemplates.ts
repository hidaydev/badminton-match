// src/config/instagramTemplates.ts

export interface PostTemplate {
  id: string
  label: string
  width: number
  height: number
  logo?: string    // center logo drawn in the header band
  footer?: string  // absolute URL path to PNG asset
}

export const instagramTemplates: PostTemplate[] = [
  {
    id: 'portrait-v1',
    label: 'Portrait 4:5',
    width: 1080,
    height: 1350,
    logo: '/instagram-logo.png',
    footer: '/instagram-footer.png',
  },
]
