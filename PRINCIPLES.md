# agmsg principles

agmsg is an open-source messaging layer for AI agent teams. As the project
grows — including work that makes agmsg usable across machines and, in the
future, hosted services operated by the maintainers — these are the
commitments we hold ourselves to. They are design constraints, not
marketing. Changes to this document are made in the open, with reasoning.

## 1. The core works on its own

The agmsg core is open source and fully functional without any server,
account, or hosted service — today's local workflow is not a demo tier.
We will not move existing core functionality behind a hosted offering.

## 2. Local-first is a design rule, not a feature

An agent's hot path never waits on a network. Messages commit locally
first; anything remote synchronizes in the background and catches up after
being offline. Remote availability may delay sync — it must never corrupt
or block local work.

## 3. The protocol is open

The synchronization protocol is specified in the open, and a self-hostable
reference server is published as open source. Anything that can talk the
protocol is a first-class citizen: a hosted service run by us is one
provider among possible providers, and interoperability is not reserved
for it.

## 4. Your data leaves with you

Whatever stores your messages — local files or a remote server — you can
export all of your data, at any time, in an open format. Leaving must
always be a supported path, not a negotiation.

## 5. Encryption is structural, not bolted on

The remote protocol carries message contents in sealed envelopes that
servers store without parsing; the server-side schema has no plaintext
message fields to begin with. End-to-end encryption is implemented as a
first-class mode, and we are honest about its limits: it protects
contents, not traffic patterns.

## 6. Commercial services sell operation, not the software

The maintainers — and anyone else; the protocol is open — may run paid
services around agmsg. What such services sell is the work of running
things: servers, storage, uptime, organization-level management. The
software itself stays open, and any boundary between open code and a paid
service is drawn in the open.

## 7. Community changes are judged by open-source value

Contributions and design changes to the core are evaluated by what they do
for open-source users. Requirements that originate from a hosted or
commercial context must earn their place by having standalone value in the
open-source project, and are declined otherwise.

---

*This document states our current commitments and how we intend to keep
working. It is versioned with the repository; if it ever needs to change,
the change and its reasoning will be public.*
