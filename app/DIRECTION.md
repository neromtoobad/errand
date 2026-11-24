# Errand page: design direction

**Metaphor: the errand route.** The logo is an arc between two dots. That arc is
also the trip each errand makes: it leaves Base Sepolia when money frees up,
goes up to Reactive Lasna, and comes back down to the lender's wallet. The page
draws that arc and moves a courier along it, driven only by real chain events
(or, when replaying, by a real round's block numbers).

**What we took from references** (principles only, no layouts or palettes):
- [Plainrate](https://plainrate.framer.website/): tight display type (about -4%
  tracking, line height near 1), large plain numerals, a row of small mono
  "trust" ticks under the lede, 22–28 px card radii.
- [Clario](https://clario.framer.website/): one dark instrument panel on an
  otherwise light page, so the live part reads as a tool.

**Tokens**
- Paper `#f3f2ec`, card `#fff`, ink `#121211`, lime `#d4f25a` (errand / done),
  board `#141413` (the live panel).
- Schibsted Grotesk for words, JetBrains Mono for numbers, addresses and ticks.
- Radii 22 px cards, 28 px board, 999 px pills.
- Motion: one ease (`cubic-bezier(.2,.8,.2,1)`), numbers count up, sections
  rise 12 px on first view, courier moves along the arc. All off under
  `prefers-reduced-motion`.

**Rules**
- Every moving thing is tied to chain data. No timers pretending to be events.
- First line says what it does. Plain verbs.
