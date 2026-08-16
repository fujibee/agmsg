# Reference

**Nobody is building toward anything in a `ref/` directory.** These are kept
for what they worked out, not as a description of the product or a plan for it.

Some were reviewed, some reviewed many times. A passed review says the
reasoning holds together — not that the design was adopted. Some say
"implemented", describing code that exists rather than a commitment to keep it.
Read every normative-sounding sentence here as *"if this had been adopted, it
would have worked like this."*

Do not implement from a document under `ref/`. Do not cite one as the reason
something is the way it is. Do not build a runbook or a README step from one.

Work that is actually being built toward lives in the parent directory, whether
or not any code exists yet.

## Why this exists

A document here recorded that the shipped onboarding creates a team in the
opposite order from the intended one, and named the schema constraints causing
it. Work continued against the shipped order for two days — nobody treated the
document as a gate, because a status line inside a file is connected to
nothing, and the files beside it described working code. A runbook was then
written teaching a command that the same directory said should not exist.

Splitting by directory makes the distinction visible from the path, before the
file is opened.

## Using these

They remain worth reading. Constraints, failure modes, and wire shapes worked
out here often survive a change of direction even when the design around them
does not — that reasoning is why they were kept rather than deleted. Take the
argument; do not take the conclusion as current.
