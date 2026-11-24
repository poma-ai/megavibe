# Production access discipline

Rules for touching a live production system — a Kubernetes cluster, a managed
database, a running service. They apply whenever the target is not visibly a
dev/test/staging environment. A dev, test or staging label does not exempt code
that is connected to a live production database or to production side-effect
channels (see below).

## The command class that gets mistaken for a read

`kubectl exec`, `attach`, `cp`, `debug` and `port-forward` (and the `oc`
equivalents) are **writes**. Not because of what you type after `--`, but
because of what they are: they start a process inside a live production
container, or open a tunnel into one.

This is the trap. Wanting to print an env var or a library version *feels* like
reading, so the command inherits the safety category of the `get` calls around
it. The mechanism is what decides the category, not the intent.

Two ways it bites:

- **Memory.** A common cluster convention is `request.mem == limit.mem`
  (Guaranteed QoS) — zero headroom, deliberately. Services that size their own
  caches from the pod's memory budget then sit near the ceiling by design. Start
  a Python interpreter in that cgroup and the kernel's OOM killer takes the
  *largest* process: the server, not your shell. You will not see your own
  command fail.
- **Escalation by increment.** `get secret` → `get pods` → `exec … env` →
  `exec … python`. Each step is a small delta on the last, so no step forces a
  re-check of the category. The final command would never have passed on its
  own; it passed because it was step four.

**Get the fact from the manifest instead.** `kubectl get`/`describe`, the image
tag, the Deployment's env block, the sealed secret, the ConfigMap, the repo.
These answer nearly every question `exec` gets reached for, and they answer it
without entering the container. If the manifest genuinely cannot answer it, that
is a question for the human, not a command to issue on your own initiative.

**Never spend production risk to confirm something you already have adequate
evidence for.** Marginal confidence is not worth a live container.

## The guard

`block-dangerous-bash.sh` blocks the exec class when the namespace (`-n` /
`--namespace`) or context (`--context`) does not visibly name a non-prod
environment. Fail-closed: `kubectl exec` with no namespace flag uses the context
default, which can be anything, so it blocks.

Matching is **component-wise** — the value is split on `- _ . : /` and each part
compared whole, never as a substring. `prodev`, `citadel`, `special-prod` and
`my-device-prod` are therefore production, and any component that names
production (`prod`/`prd`/`production`/`live`) blocks outright so
`qa-mirror-of-prod` cannot pass on its `qa`. If the current context in
`KUBECONFIG` is visibly local (docker-desktop, minikube, kind, k3d, colima,
orbstack, rancher-desktop) everything is allowed, so ordinary local development
in the `default` namespace is untouched.

- Widen the safe list: `MEGAVIBE_NONPROD_PATTERN` (space- or pipe-separated).
- Go in deliberately: `MEGAVIBE_ALLOW_PROD_EXEC=1`, per session, when a human
  has decided to.

Parsing uses Python's `shlex`, not a regex (a regex first cut was defeated by
`bash -c`, quoting, line continuations and `#` inside a word). Without
`python3` the guard skips rather than blocks, as `rm-to-trash.sh` does; when
`python3` is there but the check fails to run, it blocks if the text names an
exec-class verb. A `$( )` inside double quotes is checked as a command, since
bash runs it.

The obviously-mutating verbs (`apply`, `patch`, `delete`, `scale`,
`rollout restart`) are **not** blocked: nobody mistakes those for reads, and
blocking them would break ordinary operations. The guard covers the one class
that disguises itself.

## Changing a Deployment restarts it

Any edit to a Deployment's pod template — including adding a single env var —
creates a new ReplicaSet and rolls every pod. A GitOps sync of a manifest PR is
therefore a production restart, even when the PR looks like configuration.

Two consequences worth holding:

- A service can run healthy for weeks while the config it would load on boot
  drifts underneath it. The next restart is when the drift bites, and the
  trigger will look unrelated to the breakage.
- When something breaks shortly after a restart, the merged manifest PR is the
  first suspect, not the last.

## A request to an application is whatever its handler does

The `exec` trap again, over HTTP. Classify a request to an application that
runs against production data by what it is established to do, never by its URL,
the page's name, the size of its output or its HTTP method: a GET does whatever
the code behind it does, and legacy pages act on load.

Example (2026-11-15): six plain GETs of a "read-only" admin page queued about
70,000 mails; the page had been classified by its name and output size.

- **Establish the effects of each route before you request it**, browser
  navigation included, from evidence that applies to it: the handler and what
  it calls (middleware, helpers, queued work), read for database writes, mail
  and queue inserts, payment calls, webhooks and other outbound requests; or a
  documented read-only contract (a health endpoint, a published API); or an
  earlier verification whose code and configuration have not changed since.
  Source access is not required where an applicable contract establishes the
  effects. One page read does not vouch for the next one in the list.
- If the available evidence does not establish the effects, do not call the
  request read-only: use an isolated environment, or get the user's agreement
  to that specific request and its uncertainty.
- Repeating a list of requests "to compare output" repeats whatever each
  handler does.

## Staging wired to production data is production

A staging directory or a localhost address isolates the code, not its effects.
Code connected to the production database or to production integrations can
change live state and trigger real actions: the mail queue, payment, webhooks,
external APIs. Establish what the copy is actually connected to (config,
credentials, enabled senders and consumers) before testing. A separate database
copy with test-only integrations is not a live connection, though copied
personal data still needs its protection.

Before a run against live production data or channels, work through the three
points below. A bounded request covered by an applicable documented read-only
contract is the exception: the contract establishes its side-effect scope, and
access to internal code or configuration, or changes to integrations, are not
needed just to make that request. Check what can be observed and say what was
not. The exception does not hold where the code or configuration under test
could invalidate the contract.

- **Identify the side-effect channels this test can reach**, from the code paths
  it exercises, the configuration and the background consumers that pick up
  rows. Record the evidence and what you could not resolve; an incomplete list
  is not proof of isolation.
- **Isolate the test's effects through its own configuration**: a separate
  database, test credentials, a sink address. Do not switch off a shared
  production sender, redirect production traffic or move production rows to
  make a test safe; that changes the service for everyone and needs the user's
  explicit agreement to that action. If isolation is incomplete, name the
  remaining effects and get agreement to the run first; telling the user is not
  the same as their agreeing.
- **Decide what you expect to change and how you will see it, then look after
  every request or small batch.** Prefer records that can be attributed to the
  test (rows it enqueued, delivery, payment or webhook events) over a bare
  queue length: ordinary traffic moves counts, and a queue can fill and drain
  between two looks. Stop on an effect you did not expect, or when you can no
  longer see what you need to.

A single request can already do bulk harm, so looking afterwards supplements
isolation and never replaces it. Verification then says which effects were
checked, on what evidence, and what stays unknown; unchanged counts alone do
not show a test was clean.

## Checking production without loading it

- Light statements only: known cheap, indexed lookups with bounded work, or
  existing monitoring. A COUNT or a LIMIT bounds the output, not the rows
  examined, joined or sorted. Know the expected work before you run a
  statement and use the per-statement time and lock-wait limits the database
  offers; if the cost is unknown, use another source of evidence or ask first.
  A heavy check query can lock the very thing it checks.
- After anything slow, look at the process list, and cancel only your own
  statement.
- Never print raw statement text from a process list or a query log: it carries
  personal data. Print ids, states and durations.

## When you find harm your own work is causing

Halting is the first step, not the response.

1. **Stop your own activity**: issue no further test requests, stop your test
   driver or server.
2. **Tell the user at once**: what you observed, whether it is still going on,
   what is uncertain, and which containment you propose. Do not wait for a
   complete measurement or a finished remedy to raise it. Check the timeline
   before you state the cause (see the next section).
3. **Contain further harm within what you are authorised to do.** Changing
   production state, such as moving queued rows aside, disabling a route or
   pausing a sender, needs the user's agreement to that action, however
   reversible it is; have the exact action, its scope and its rollback ready
   when you ask.

   The sole exception is one reversible hold per incident, while further harm
   from your test is demonstrably still occurring. Ask for the exact action in
   chat first, with a deadline the observed urgency justifies, and give the
   user a real chance to reply: a message that has merely not been answered yet
   does not qualify, and a refusal or "wait" overrides the exception. When the
   deadline has passed without a reply, act only on pending items that are
   attributable to your test by request or job identifiers or equally specific
   evidence; a time window or a rising count is not attribution. The hold must
   keep the items and their original state, be safe against concurrent
   consumers, and touch no unrelated work, shared service or shared
   configuration. If any of that cannot be established, wait for approval and
   keep preparing the remedy. Park, never purge, and do not replay parked work
   on your own. Record the evidence, the action and its rollback, and report at
   once.
4. **Establish who and what is affected** from the evidence available:
   confirmed counts, estimates and unknowns, each with how it was established.
5. **Prepare the remedy while you wait** and bring it ready to execute: the
   correction drafted and checked where it cannot go out by itself, the fix as
   a reviewed diff. Sending, deploying and every other step that is destructive
   or reaches other people waits for the user's word; ask for it in chat.
   Silence is not approval.
6. **Complete the report** as evidence and preparation progress: what happened,
   what was done, what remains at risk, which decisions are open.

Stopping, reporting and then waiting for instructions leaves the user to design
the remedy while the damage ages. Needing approval to execute a step is no
reason not to have prepared it.

## When you are blamed for an incident

Reconstruct the timeline from artifacts **before** accepting it. ReplicaSet
creation timestamps, GitOps sync history, the merge time of deploy PRs, and your
own tool calls — all of it is checkable in minutes.

State what you did and did not do, with evidence, and name the cause you believe
is real. Own the boundary you actually crossed; correct the causal claim that is
not yours.

A confident, well-written false confession is worse than a wrong answer. It is
built to be believed, so it ends the investigation at the wrong place while the
real cause stays live and ready to fire again. Agreeing with an angry user is
not the same as being useful to one.
