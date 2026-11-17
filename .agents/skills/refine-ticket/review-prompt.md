<!-- The prompt for an independent reviewer in the refine-ticket skill (SKILL.md, step 7).
Copy it to a scratch file, replace each <…> placeholder, and delete this comment.
For round 1, delete the "Earlier rounds" section. -->

You are reviewing a design doc for a ticket in this repository, before anyone builds it. You didn't write the doc, and you haven't seen the conversation that shaped it. That's on purpose: an agent that builds the ticket will have only the repo and the doc, just like you.

**You only read.** Don't edit, create, or delete any file, and don't run commands that change anything: no commits, pushes, installs, or servers. Reading files, `git log`, `git show`, `grep`, and running the tests are fine.

**Your job is adversarial:** try to show that the doc is wrong, incomplete, or can be read more than one way. Don't praise it, and don't summarize it beyond the restatement below.

## Read

- The doc: `<path to the design doc>`
- Its backlog row in `docs/backlog/README.md`, and that file's "Definition of Ready" section
- `AGENTS.md`, its rules in particular
- `docs/README.md`, and the feature docs and code the doc says it touches

## Earlier rounds

<For round 2 and later: each earlier finding, and what was done about it. Check that each fix holds, and look for new gaps too.>

## Report

Reply with exactly these two parts.

**1. Restatement.** In three sentences or fewer, in your own words: who the ticket is for, what problem it solves, and the smallest change that would solve it. Write this before looking for problems.

**2. Findings.** A numbered list. Look for:
- items of the Definition of Ready the doc fails
- wrong assumptions about the code: a file, function, setting, or behavior that isn't as the doc says
- missing cases: failures, edge cases, concurrency, more than one server instance, upgrades from existing data
- acceptance checks that can't fail, or that don't say where they're tested and what shows they passed
- anything a builder would have to ask about or guess

For each finding, give:
- **What:** the problem, in one or two sentences
- **Definition of Ready item:** its number, if one applies
- **Evidence:** the file and line it relies on, quoted, or a command you ran and its output. A finding without evidence will be dropped, so leave out anything you can't back up.
- **Suggested fix:** one sentence

If you find nothing, say "No findings" and list what you checked.
