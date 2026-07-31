# Showcase image provenance

Where each image in this directory came from, and on what basis it is used
here. This file is tracked and ships with the site so the information travels
with the images rather than living only in a pull request.

## agmsg-bubblelog.png

- Upstream: https://github.com/dreiachse-cyber/agmsg-bubblelog
- Licence: MIT — Copyright (c) dreiachse-cyber
- Source asset: `docs/assets/demo.gif` in that repository
- Derivation: one frame extracted and cropped to 1066x600 (the card's 16:9). No
  other alteration. The source GIF is portrait, so an uncropped image would have
  been shown as a horizontal band by the card's `object-cover`.

MIT requires the copyright notice **and the permission notice** to accompany
copies, so the upstream licence is reproduced verbatim beside the image as
`agmsg-bubblelog.LICENSE.txt`. Naming the licence is not the same as including
it; the file is what satisfies the condition.

## agmsg-tui.png

- Upstream: https://github.com/rrrrnmtsu/agmsg-tui
- Source asset: the repository's GitHub social preview card, from
  `https://opengraph.githubassets.com/1/rrrrnmtsu/agmsg-tui`
- Derivation: none — saved as served, 1200x600

GitHub generates this card so that other sites can show it when linking to the
repository, which is what a showcase entry pointing at that repository does. It
is not part of the repository's source, so the project's own licence is not what
governs it; the basis is the card's purpose.

It is still a placeholder. The project is a terminal client and deserves a real
capture, which should come from its author rather than from us — replace it when
one is offered.

## agkanban.png, agmsg-office.png, agmsg-viewer.png

These predate this file and their provenance was not recorded at the time. They
are not covered by the entries above — someone with that history should fill
them in rather than assume they were obtained the same way.
