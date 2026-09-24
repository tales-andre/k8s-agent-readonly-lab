#!/usr/bin/env node
// Lists the tools an MCP server exposes (tools/list) and optionally tries to call one
// directly (tools/call), speaking JSON-RPC over stdio. No SDK, no cluster changes.
//
// Usage:
//   node scripts/mcp-tools.mjs <version> [--flag NAME=value]... [--call toolName [--args '{json}']]...
// Example:
//   node scripts/mcp-tools.mjs 4.1.7 --flag ALLOW_ONLY_NON_DESTRUCTIVE_TOOLS=true --call kubectl_delete
import { spawn } from 'node:child_process';

const [version, ...rest] = process.argv.slice(2);
if (!version) { console.error('usage: mcp-tools.mjs <version> [--flag K=V] [--call tool]'); process.exit(1); }
const env = { ...process.env };
const calls = [];
for (let i = 0; i < rest.length; i++) {
  if (rest[i] === '--flag') { const [k, v] = rest[++i].split('='); env[k] = v; }
  if (rest[i] === '--call') calls.push({ name: rest[++i], arguments: { resourceType: 'pod', name: 'does-not-exist', namespace: 'default' } });
  if (rest[i] === '--args') calls[calls.length - 1].arguments = JSON.parse(rest[++i]);
}

const child = spawn('npx', ['-y', `mcp-server-kubernetes@${version}`], { env, shell: process.platform === 'win32' });
let buf = '';
const pending = new Map();
child.stdout.on('data', (d) => {
  buf += d;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
    if (!line.startsWith('{')) continue;
    const msg = JSON.parse(line);
    if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
  }
});
let nextId = 1;
const request = (method, params) => new Promise((resolve) => {
  const id = nextId++;
  pending.set(id, resolve);
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
});

const timer = setTimeout(() => { console.error('timeout'); child.kill(); process.exit(2); }, 120000);
const init = await request('initialize', {
  protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'readonly-lab', version: '1.0.0' },
});
child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
const list = await request('tools/list', {});
const out = {
  server: init.result?.serverInfo,
  flags: rest.filter((a, i) => rest[i - 1] === '--flag'),
  toolCount: list.result.tools.length,
  tools: list.result.tools.map((t) => t.name).sort(),
};
if (calls.length) out.calls = [];
for (const call of calls) {
  const res = await request('tools/call', call);
  out.calls.push({ tool: call.name, arguments: call.arguments, response: res.error ?? res.result });
}
console.log(JSON.stringify(out, null, 2));
clearTimeout(timer);
child.kill();
process.exit(0);
