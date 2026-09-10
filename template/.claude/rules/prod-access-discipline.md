# Production access discipline

Rules for touching a live production system — a Kubernetes cluster, a managed
database, a running service. They apply whenever the target is not visibly a
dev/test/staging environment.

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

Parsing uses Python's `shlex`, not a regex. A regex first cut was defeated by
`bash -c "kubectl exec …"`, by `kube'ctl' exec`, by a backslash-newline
continuation between `kubectl` and `exec`, and by `COLOR=#ff00aa kubectl exec …`
(a `#` inside a word is not a comment) — and it wrongly blocked
`kubectl get pod exec` by scanning every word for the verb instead of parsing
the subcommand. Shell is not a regular language. Without `python3` the guard
skips rather than blocks, the same posture `rm-to-trash.sh` takes.

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
