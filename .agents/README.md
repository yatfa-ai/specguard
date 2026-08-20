# `.agents/`

Runbooks written **by** an agent, **for** an agent (or a person) who has to repeat an operation on
the SpecGuard platform.

Each file records a procedure that was actually executed, with the commands that were run, the
output that came back, and the reasoning about what could go wrong. They are not aspirational docs:
if a step is in here, it ran.

## Conventions

- **Every step is idempotent.** Re-running a runbook must not create a duplicate or destroy
  anything. Where a command creates a row, it is written as find-or-create.
- **Secrets never appear in a runbook, and never in a terminal.** Where a procedure produces a
  credential, the command redirects it straight to a file with `600` permissions. A runbook names
  the file path; it never contains the value.
- **Observed facts carry a date.** Prod state, deployed image tags and schema shapes rot. A claim
  about the platform states when it was measured, so a later reader can tell a fact from a fossil.
- **Where the manual path is a stand-in for a missing product capability, say so and link it.**
  These runbooks are the specification for the automation that should eventually replace them.

## Index

| Runbook | What it does | Replaced by |
| --- | --- | --- |
| [`add-repository.md`](add-repository.md) | Registers a GitHub repository on the platform and issues its ingest key | SPGD-750 |
