# k8s-agent-readonly-lab

[![lab](https://github.com/tales-andre/k8s-agent-readonly-lab/actions/workflows/lab.yml/badge.svg)](https://github.com/tales-andre/k8s-agent-readonly-lab/actions/workflows/lab.yml)

What actually stops an AI agent from changing your Kubernetes cluster?

This lab tests three layers of control on [mcp-server-kubernetes](https://github.com/Flux159/mcp-server-kubernetes)
**v4.1.7**, a popular MCP server that gives AI agents access to a cluster. Every number below comes from
a script in this repo and the raw output is in [`evidence/`](./evidence/).

| Layer | Control | Blocks writes? | Evidence |
|---|---|---|---|
| Server flag | `ALLOW_ONLY_NON_DESTRUCTIVE_TOOLS=true` | **No.** 8 of the 18 tools left can still change the cluster | [`flags-non-destructive.json`](./evidence/flags-non-destructive.json) |
| Server flag | `ALLOW_ONLY_READONLY_TOOLS=true` | Yes, at the tool level: 8 read tools, enforced on `tools/call` | [`flags-readonly.json`](./evidence/flags-readonly.json) |
| Identity | ServiceAccount bound to the `view` ClusterRole | **Yes, at the API server**, even with all 23 tools exposed | [`rbac-as-view-serviceaccount.json`](./evidence/rbac-as-view-serviceaccount.json) |

**In short:** "non-destructive" means *won't delete*, not *won't change*. RBAC is the only layer that the
Kubernetes API server itself enforces.

---

## 1. What each flag exposes

Tool lists come straight from the MCP handshake (`tools/list`), with no SDK or client in between.

| Mode | Tools exposed |
|---|---|
| No flag | 23 |
| `ALLOW_ONLY_NON_DESTRUCTIVE_TOOLS=true` | 18 (removes `kubectl_delete`, `uninstall_helm_chart`, `cleanup`, `kubectl_generic`, `node_management`) |
| `ALLOW_ONLY_READONLY_TOOLS=true` | 8 (`kubectl_get`, `kubectl_describe`, `kubectl_logs`, `kubectl_context`, `kubectl_reconnect`, `explain_resource`, `list_api_resources`, `ping`) |

The 18 tools left by the non-destructive flag:

- **Can change the cluster (8):** `kubectl_apply`, `kubectl_create`, `kubectl_patch`, `kubectl_scale`,
  `kubectl_rollout`, `exec_in_pod`, `install_helm_chart`, `upgrade_helm_chart`
- **Open network tunnels (2):** `port_forward`, `stop_port_forward`
- **Read (8):** the same 8 as read-only mode

This is not a bug. It is how the flag is designed: in the server source, "destructive" is defined as
delete and uninstall operations.

## 2. Is the filter enforced when a tool is called directly?

It is in v4.1.7. Before v3.6.0 it was not:
[CVE-2026-46519](https://nvd.nist.gov/vuln/detail/CVE-2026-46519) (CVSS 8.8) describes these flags as
filtering `tools/list` only, so any client that knew a tool's name could still call it.

Tested on v4.1.7 by calling a hidden tool directly:

- `kubectl_delete` under the non-destructive flag: `Tool 'kubectl_delete' is not allowed under the current server configuration`
- `kubectl_apply` under the read-only flag: `Tool 'kubectl_apply' is not allowed under the current server configuration`

A filter that has already failed once is a reason not to make it your only line of defense.

## 3. RBAC: the same calls, two identities

[`scripts/rbac-test.sh`](./scripts/rbac-test.sh) creates a throwaway [kind](https://kind.sigs.k8s.io/)
cluster, runs the server with **no filtering flag (all 23 tools exposed)**, and makes the same six
calls twice: as cluster-admin, and as a ServiceAccount bound to the built-in `view` ClusterRole
([`manifests/agent-readonly-rbac.yaml`](./manifests/agent-readonly-rbac.yaml)).

| Tool call | cluster-admin | `view` ServiceAccount |
|---|---|---|
| `kubectl_get` pods | ✅ allowed | ✅ allowed |
| `kubectl_apply` a ConfigMap | ✅ created | ⛔ Forbidden |
| `kubectl_scale` deployment to 2 | ✅ scaled | ⛔ Forbidden |
| `kubectl_patch` deployment labels | ✅ patched | ⛔ Forbidden |
| `exec_in_pod` `cat /etc/hostname` | ✅ executed | ⛔ Forbidden |
| `kubectl_delete` the ConfigMap | ✅ deleted | ⛔ Forbidden |

The tools and the arguments were the same in both runs. The only difference was the identity, and the
API server rejected every write from the `view` account.

## 4. And the prompt?

Instructions shape behavior; they don't remove capability. A runbook or a system prompt can make an
agent more predictable, but if its identity is allowed to write, the prompt is the only thing between
the agent and a change. This lab does not measure prompt effects. Its point is narrower: RBAC is the
only layer the Kubernetes API server enforces.

## Takeaways

1. **Give the agent an identity, not just a flag.** Run it as a ServiceAccount with `view`, or a tighter
   Role. That is the only layer the API server enforces.
2. **If you use a server flag, pick it by what it blocks, not by its name.** `ALLOW_ONLY_READONLY_TOOLS`
   is read-only. `ALLOW_ONLY_NON_DESTRUCTIVE_TOOLS` is not.
3. **Pin the server version.** `npx -y mcp-server-kubernetes` without a version pulls whatever is latest,
   which could be a version where the filter doesn't hold.
4. **Treat prompts and runbooks as behavior.** They can make the agent more predictable, but they are
   not a security control.

## Reproduce

Requirements: Node.js 18+, for the RBAC test Docker, kind and kubectl, and jq for the evidence check.

```bash
# What each flag exposes (no cluster needed)
node scripts/mcp-tools.mjs 4.1.7
node scripts/mcp-tools.mjs 4.1.7 --flag ALLOW_ONLY_NON_DESTRUCTIVE_TOOLS=true --call kubectl_delete
node scripts/mcp-tools.mjs 4.1.7 --flag ALLOW_ONLY_READONLY_TOOLS=true --call kubectl_apply

# RBAC test (creates and deletes a kind cluster named readonly-lab)
bash scripts/rbac-test.sh 4.1.7

# Check that evidence/ still says what the tables above say
bash scripts/check-evidence.sh
```

## Limits

- One server version (4.1.7), tested on 2026-09-23 with a kind cluster running Kubernetes v1.27.
- `view` is a broad built-in role. It can't read Secrets, but it can read most other resources. In
  production, scope the agent to the namespaces and resources it actually needs.
- This lab tests capability, not intent. It doesn't evaluate prompt injection or what an agent would
  *choose* to do.
- Everything runs locally: the flag checks need no cluster, and the RBAC test uses a throwaway kind
  cluster. Nothing here ran against a cloud account or a managed Kubernetes service.
- The [`lab`](./.github/workflows/lab.yml) workflow re-runs both tests on a GitHub-hosted runner (fresh
  kind cluster, kind v0.33.0 with its default Kubernetes v1.37 node) on every push, checks the results
  against the tables above and keeps the raw output as a run artifact. The date of the latest run is on
  the [Actions page](https://github.com/tales-andre/k8s-agent-readonly-lab/actions/workflows/lab.yml).

## License

MIT. See [LICENSE](./LICENSE).
