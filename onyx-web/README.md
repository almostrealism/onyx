# onyx-web

The marketing site for Onyx — static Astro, deployed to Cloudflare Pages at
**www.almostrealism.ai**. Same shape as `ringsdesktop/rings-web`, its own design.

## Develop

Needs Node 18+ (this machine's default `node` is 16 — use Homebrew's):

```sh
export PATH="/opt/homebrew/opt/node@24/bin:$PATH"
npm install
npm run dev        # http://localhost:4322
```

## Deploy

```sh
npm run deploy           # production
npm run deploy:staging   # staging branch
```

`wrangler` will prompt to authenticate the first time. The Pages project is
`onyx-web`; the custom domain (`www.almostrealism.ai`) is attached once, in the
Cloudflare dashboard under the project's Custom Domains tab.

## Editing

Anything version-specific — download URL, version number, requirements — lives in
`src/config/site.ts`. Bumping a release means editing `LATEST_VERSION` there and
nothing else.

Sections are `src/components/sections/`; there's no component library beyond that
because the site is two pages.
