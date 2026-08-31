# Google Ads — keyword plan for Onyx

Starting keyword set for search advertising, grouped so each block can be
pasted into its own ad group. Tight, single-theme ad groups are what earn
a decent Quality Score; one big group of everything is the usual way to
overpay.

Match-type syntax is included, so blocks paste in as-is:

- `"phrase match"` — the meaning must be contained in the query
- `[exact match]` — the query must mean essentially this
- bare words — broad match; only worth using with smart bidding and a
  hard eye on the search-terms report

Not included: bids, budgets, or ad copy. Those depend on what a download
is worth to you, which is a question the product doesn't answer for
itself — Onyx is free, so there's no revenue per conversion to work back
from.

---

## Read this before spending anything

**"Onyx" is a badly contested brand term.** Searches for it are dominated
by things that aren't this:

| What people mean by "onyx" | Why it's a problem |
| --- | --- |
| **OnyX** by Titanium Software | A famous *free macOS maintenance app*. Same name, same platform, far more search volume. The single biggest source of wasted spend here. |
| Onyx Boox | E-reader hardware brand |
| ONYX Graphics | Wide-format printing RIP software |
| Black onyx | Gemstone / jewellery |
| Onyx tonneau covers | Truck accessories |

So: qualify every brand keyword (`onyx terminal`, never bare `onyx`), and
apply the negative list at the bottom at **campaign** level before the
first click.

---

## Ad group 1 — SSH client for Mac

Highest commercial intent in the set. Someone typing this is shopping.

```
"ssh client for mac"
"best ssh client mac"
"mac ssh client gui"
"ssh manager mac"
"ssh connection manager mac"
"macos ssh client"
"ssh gui mac"
"putty for mac"
"putty alternative mac"
[ssh client for mac]
[best ssh client for mac]
[ssh manager for mac]
```

## Ad group 2 — Terminal app / overlay

Bigger volume, vaguer intent, more competition. Expect a higher cost per
click than group 1.

```
"best terminal for mac"
"mac terminal app"
"terminal emulator for mac"
"macos terminal alternative"
"modern terminal mac"
"dropdown terminal mac"
"hotkey terminal mac"
"quake style terminal mac"
"terminal overlay mac"
[best terminal for mac]
[terminal emulator mac]
```

## Ad group 3 — Session persistence

The actual differentiator, and phrased as the problem rather than the
category — these are people who already have the pain Onyx was built for.

```
"persistent ssh session"
"ssh session persistence"
"keep ssh session alive"
"ssh reconnect automatically"
"ssh disconnects when mac sleeps"
"resume ssh session after disconnect"
"tmux session manager"
"tmux gui mac"
"tmux client for mac"
[persistent ssh sessions mac]
[ssh keeps disconnecting mac]
```

## Ad group 4 — Fleet / server monitoring

```
"monitor remote servers mac"
"server monitoring app mac"
"remote server cpu monitor"
"monitor multiple servers dashboard"
"gpu monitoring remote server"
"nvidia gpu monitor remote"
"amd gpu monitoring linux"
"docker container monitoring mac"
"homelab monitoring app mac"
"ssh server dashboard mac"
[remote server monitoring mac app]
[monitor gpu usage remote server]
```

## Ad group 5 — AI agents / Claude Code

Low volume, almost no competition, and exactly on-thesis. Cheap to leave
running even when it converts slowly.

```
"claude code terminal"
"claude code hooks"
"manage multiple claude code sessions"
"claude code permission prompt"
"mcp server mac app"
"ai agent session manager"
"monitor ai agent terminal"
[claude code session manager]
[claude code hooks setup]
```

## Ad group 6 — Competitor alternatives

Usually the best converters in a set like this: the searcher has already
decided they want something and is only choosing what.

```
"iterm2 alternative"
"warp terminal alternative"
"termius alternative"
"tabby terminal alternative"
"royal tsx alternative"
"securecrt alternative mac"
"servercat alternative"
"wezterm alternative"
"hyper terminal alternative"
"free warp alternative"
[iterm2 alternative mac]
[termius alternative mac]
```

> Google permits **bidding** on competitor trademarks, but generally not
> using them in ad text. Write "an alternative to the terminal you're
> using", not the brand name, or the ad gets disapproved.

## Ad group 7 — PR / pipeline watching

```
"github actions status desktop app"
"github pull request dashboard"
"gitlab pipeline monitor desktop"
"open pull requests dashboard mac"
"ci pipeline status menu bar mac"
[github actions desktop notifications]
```

## Ad group 8 — Brand

Cheap and defensive, so a competitor bidding on your name doesn't get the
click for free. Every term is qualified on purpose — see the warning
above.

```
[onyx terminal]
[onyx terminal mac]
[onyx ssh client]
[almost realism onyx]
[onyx overlay terminal]
"onyx terminal app"
```

---

## Negative keywords

Apply at **campaign** level. The first block is the same-name collisions
and is the one that matters; the rest is ordinary hygiene.

```
boox
e-reader
ereader
titanium software
maintenance
cleaner
cleaning
repair permissions
cache cleaner
rip software
onyx graphics
wide format
printer
stone
marble
countertop
slab
tile
gemstone
jewelry
necklace
ring
bead
nail
polish
salon
truck
tonneau
bed cover
jeep
boat
coffee
gym
windows
linux desktop
android
ipad
iphone
chrome extension
crack
torrent
free download full version
salary
jobs
```

---

## Where to start

On a modest budget, run **groups 1, 3 and 6** only. They have the
tightest intent match and the least wasted spend. Add group 5 whenever —
it's nearly free. Leave group 2 until last: it's the most expensive and
the least qualified.

Then let the **search terms report** do the work. Every week, move
anything irrelevant into the negative list and promote anything that
converts into its own exact-match keyword. The list above is a starting
hypothesis; the search terms report is the evidence.

## A measurement caveat

The site is [consent-first](../../onyx-web/src/layouts/Layout.astro):
Google Analytics is denied until a visitor accepts, so anyone who
declines is not tracked and their download is not attributed. Consent
Mode's modelled conversions fill some of that in, but **reported
conversions will sit below reality** — don't judge a keyword dead on
thin numbers alone.

Also: there is no purchase event to optimise toward, so the conversion
action needs to be the **DMG download click** on the site. Without that
configured, every campaign here optimises toward nothing.
