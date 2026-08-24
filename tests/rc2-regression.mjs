import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';
import { promisify } from 'node:util';
import { pathToFileURL } from 'node:url';

const execFileAsync = promisify(execFile);
const require = createRequire(import.meta.url);
const PNPM_ROOT = '/opt/dsh/runtime/node_modules/.pnpm';
const TEST_CREDENTIAL = ['rc2', 'offline', 'fixture', 'credential'].join('-');
const BASE_URL = 'http://provider.invalid///';

function packageEntry(name) {
  const exact = `@deepseek-ai+${name}@0.1.1-rc.2`;
  const entries = require('node:fs').readdirSync(PNPM_ROOT)
    .filter((item) => item === exact || item.startsWith(`${exact}_`));
  assert.equal(entries.length, 1, `expected one exact rc.2 packaged module for ${name}: ${entries}`);
  const [entry] = entries;
  return path.join(PNPM_ROOT, entry, 'node_modules', '@deepseek-ai', name, 'lib', 'index.js');
}

async function loadPackage(name) {
  return import(pathToFileURL(packageEntry(name)).href);
}

async function loadSharp() {
  const entry = require('node:fs').readdirSync(PNPM_ROOT).find((item) => item.startsWith('sharp@'));
  assert.ok(entry, 'packaged sharp module is missing');
  return (await import(pathToFileURL(path.join(PNPM_ROOT, entry, 'node_modules', 'sharp', 'dist', 'index.mjs')).href)).default;
}

const [attachmentLocal, attachment, deepseek, permission] = await Promise.all([
  loadPackage('dsh-attachment-local'),
  loadPackage('dsh-attachment'),
  loadPackage('dsh-llm-deepseek'),
  loadPackage('dsh-permission-presets'),
]);

const {
  DeepSeekAdapter,
  DeepSeekFileId,
  DeepSeekFileStore,
  DeepSeekFilesClient,
  DeepSeekUploadIndex,
  deepSeekFileScope,
} = deepseek;
const { AttachmentId, ImageVariantId } = attachment;
const { applyKnobEvent, effectivePermissionPreset } = permission;

let failures = 0;
let passes = 0;

async function check(name, callback) {
  try {
    await callback();
    passes += 1;
    console.log(`PASS: ${name}`);
  } catch (error) {
    failures += 1;
    console.error(`FAIL: ${name}`);
    console.error(error instanceof Error ? error.stack ?? error.message : String(error));
  }
}

function jsonResponse(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

function fileObject(id, bytes, createdAt, filename = `dsh-${id}.png`) {
  return {
    id,
    object: 'file',
    bytes,
    created_at: createdAt,
    filename,
    purpose: 'user_data',
    expires_at: createdAt + 3600,
  };
}

function listResponse(files) {
  return jsonResponse({
    object: 'list',
    data: files,
    first_id: files[0]?.id,
    last_id: files.at(-1)?.id,
    has_more: false,
  });
}

function sseResponse(text = 'ok') {
  const body = [
    `data: ${JSON.stringify({ choices: [{ delta: { role: 'assistant', content: text }, finish_reason: null }] })}`,
    '',
    `data: ${JSON.stringify({ choices: [{ delta: {}, finish_reason: 'stop' }], usage: { prompt_tokens: 1, completion_tokens: 1 } })}`,
    '',
    'data: [DONE]',
    '',
    '',
  ].join('\n');
  return new Response(body, {
    status: 200,
    headers: { 'content-type': 'text/event-stream' },
  });
}

function makeReference(data) {
  return {
    attachmentId: AttachmentId(`sha256:${'1'.repeat(64)}`),
    mediaType: 'image/png',
    width: 1,
    height: 1,
    bytes: data.byteLength,
    name: 'fixture.png',
  };
}

function makeRequestVersion(data, ref = makeReference(data), variant = '2') {
  return {
    variantId: ImageVariantId(`sha256:${variant.repeat(64)}`),
    attachment: ref,
    data,
    mediaType: ref.mediaType,
    bytes: data.byteLength,
    width: ref.width,
    height: ref.height,
    depth: 'uchar',
    space: 'srgb',
    hasAlpha: false,
  };
}

async function walkFiles(root) {
  const result = [];
  async function visit(current) {
    for (const entry of await readdir(current, { withFileTypes: true })) {
      const absolute = path.join(current, entry.name);
      if (entry.isDirectory()) await visit(absolute);
      else result.push(absolute);
    }
  }
  await visit(root);
  return result.sort();
}

async function runDsh(args, extraEnv = {}) {
  const result = await execFileAsync('/nodejs/bin/node', [
    '/opt/dsh/runtime/node_modules/@deepseek-ai/dsh/lib/bin.js',
    ...args,
  ], {
    cwd: '/workspace',
    env: {
      ...process.env,
      DSH_HOME: '/var/lib/dsh',
      ...extraEnv,
    },
    maxBuffer: 2 * 1024 * 1024,
  });
  return result.stdout;
}

await check('permission config serialization and reducer primitives match the rc.2 package contract', async () => {
  const dump = await runDsh(['--profile', 'web', '--dump-default-config']);
  const compact = dump.replace(/\s+/g, ' ');
  assert.match(compact, /mode: !!js process\.env\.DSH_PERMISSION_MODE \?\? 'workspace-write'/);
  assert.match(compact, /\(process\.env\.DSH_PERMISSION_MODE \?\? 'workspace-write'\) === 'danger-full-access' \? 'never' : 'ask'/);
  assert.match(compact, /read-only: sandbox: read-only approval: ask/);
  assert.match(compact, /workspace-write: sandbox: workspace-write approval: ask/);
  assert.match(compact, /danger-full-access: sandbox: danger-full-access approval: never/);

  const empty = { preset: null, sandbox: null, approval: null };
  assert.strictEqual(applyKnobEvent(empty, { type: 'unrelated', data: {} }), empty);
  const folded = applyKnobEvent(
    applyKnobEvent(empty, { type: 'permission/preset', data: { preset: 'workspace-write' } }),
    { type: 'approval/policy', data: { policy: 'never' } },
  );
  assert.deepEqual(folded, { preset: 'workspace-write', sandbox: null, approval: 'never' });
  assert.equal(effectivePermissionPreset([
    { type: 'permission/preset', data: { preset: 'read-only' } },
    { type: 'permission/preset', data: { preset: 'workspace-write' } },
  ]), 'workspace-write');
});

await check('request-image persistence, path normalization, cache reuse, and image bounds', async () => {
  const sharp = await loadSharp();
  const home = await mkdtemp('/tmp/dsh-rc2-attachments-');
  const root = path.join(home, 'attachments', 'v1');
  try {
    const source = new Uint8Array(await sharp({
      create: {
        width: 8,
        height: 4,
        channels: 3,
        background: { r: 40, g: 120, b: 220 },
      },
    }).png().toBuffer());
    const limits = {
      maxImageBytes: 20 * 1024 * 1024,
      maxImagePixels: 1000,
      maxImageDimension: 100,
    };
    const normalized = await attachmentLocal.saveImageFile(root, {
      data: source,
      mediaType: 'image/png',
      name: '../../outside-name.png',
    }, limits, { maxDimension: 2, maxBytes: 1024 * 1024 });
    assert.equal(normalized.name, 'outside-name.png');
    assert.deepEqual(normalized.originalDimensions, { width: 8, height: 4 });
    assert.ok(normalized.width <= 2 && normalized.height <= 2);
    const objectPath = path.join(root, 'objects', String(normalized.attachmentId).slice(7, 9), String(normalized.attachmentId).slice(7));
    assert.equal((await stat(objectPath)).mode & 0o777, 0o600);
    assert.equal((await stat(path.join(root, 'objects'))).mode & 0o777, 0o700);
    assert.equal((await stat(path.join(home, 'attachments'))).mode & 0o777, 0o700);
    assert.equal((await stat(path.join(home))).mode & 0o777, 0o700);
    assert.equal(require('node:fs').existsSync(path.join(home, 'outside-name.png')), false);

    const stored = await attachmentLocal.readImageFile(root, normalized);
    const policy = { maxPixels: 1, maxBytes: 1024 * 1024 };
    const request = await attachmentLocal.readRequestImageFile(root, stored, policy);
    assert.equal(request.width * request.height, 1);
    assert.equal(request.depth, 'uchar');
    assert.equal(request.space, 'srgb');
    const variantHash = String(request.variantId).slice(7);
    const cachedPath = path.join(root, 'request-images', variantHash.slice(0, 2), variantHash);
    assert.equal((await stat(cachedPath)).mode & 0o777, 0o600);
    const filesBefore = await walkFiles(root);
    const again = await attachmentLocal.readRequestImageFile(root, stored, policy);
    assert.equal(String(again.variantId), String(request.variantId));
    assert.deepEqual([...again.data], [...request.data]);
    assert.deepEqual(await walkFiles(root), filesBefore);

    await writeFile(cachedPath, Buffer.from('corrupt cache')); // exact cache path is inside our temp root
    const repaired = await attachmentLocal.readRequestImageFile(root, stored, policy);
    assert.deepEqual([...repaired.data], [...request.data]);
    assert.deepEqual(await walkFiles(root), filesBefore);

    await assert.rejects(
      attachmentLocal.saveImageFile(root, { data: source, mediaType: 'image/jpeg' }, limits, { maxDimension: 2, maxBytes: 1024 * 1024 }),
      (error) => error?.code === 'IMAGE_TYPE_MISMATCH',
    );
    await assert.rejects(
      attachmentLocal.saveImageFile(root, { data: source, mediaType: 'image/png' }, { ...limits, maxImageDimension: 2 }, { maxDimension: 2, maxBytes: 1024 * 1024 }),
      (error) => error?.code === 'IMAGE_DIMENSION_TOO_LARGE',
    );
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

await check('Files API mock succeeds and scopes credentials to the Authorization header', async () => {
  const calls = [];
  const client = new DeepSeekFilesClient({
    baseURL: BASE_URL,
    apiKey: TEST_CREDENTIAL,
    fetch: async (url, init) => {
      calls.push({ url: String(url), init });
      const form = init.body;
      assert.ok(form instanceof FormData);
      assert.equal(form.get('purpose'), 'user_data');
      assert.equal(form.get('expires_after[anchor]'), 'created_at');
      assert.equal(form.get('expires_after[seconds]'), '3600');
      const upload = form.get('file');
      assert.equal(upload.name, 'fixture.png');
      assert.deepEqual([...new Uint8Array(await upload.arrayBuffer())], [1, 2, 3]);
      assert.equal(new Headers(init.headers).get('authorization'), `Bearer ${TEST_CREDENTIAL}`);
      return jsonResponse(fileObject('file-success', 3, 1700000000, 'fixture.png'));
    },
  });
  const result = await client.upload({
    data: new Uint8Array([1, 2, 3]),
    mediaType: 'image/png',
    filename: 'fixture.png',
    expiresAfterSeconds: 3600,
  });
  assert.equal(String(result.id), 'file-success');
  assert.equal(result.bytes, 3);
  assert.equal(result.expiresAt, 1700003600);
  assert.equal(calls.length, 1);
  assert.equal(new URL(calls[0].url).pathname, '/files');
});

async function adapterConnection(modelId = 'vision-mock') {
  const config = deepseek.resolveAdapterOptions({
    apiKeyEnv: 'MOCK_KEY',
    baseURL: 'http://provider.invalid',
    thinking: 'disabled',
    models: [{ id: modelId, inputModalities: ['image'], imagePixelBudget: 1, imageMaxBytes: 1024 * 1024 }],
    fileQuotaCleanupBatch: 1,
    fileRefreshMarginSeconds: 0,
    fileExpiresAfterSeconds: 3600,
  });
  return config;
}

async function runAdapter(connection, store, version, fetchImpl) {
  const ref = version.attachment;
  const adapter = new DeepSeekAdapter({
    options: () => connection,
    resolveApiKey: async () => TEST_CREDENTIAL,
    resolveUserId: () => 'user-rc2-test',
    resolveAttachments: () => ({
      readImageRequest: async () => version,
    }),
    resolveFiles: () => store,
  });
  const previousFetch = globalThis.fetch;
  globalThis.fetch = fetchImpl;
  try {
    const chunks = [];
    for await (const chunk of adapter.stream({
      provider: 'deepseek-official',
      model: connection.models[0].id,
      messages: [{
        role: 'user',
        content: [
          { type: 'text', text: 'describe this' },
          { type: 'image', attachment: ref },
        ],
      }],
    })) chunks.push(chunk);
    return chunks;
  } finally {
    globalThis.fetch = previousFetch;
  }
}

await check('missing /files endpoint falls back to one inline base64 request', async () => {
  const home = await mkdtemp('/tmp/dsh-rc2-fallback-');
  const store = new DeepSeekFileStore({
    index: new DeepSeekUploadIndex(path.join(home, 'files-v3.json')),
    fetch: async (url) => {
      assert.equal(new URL(String(url)).pathname, '/files');
      return jsonResponse({ error: { message: 'files endpoint not found' } }, 404);
    },
  });
  const version = makeRequestVersion(new Uint8Array([1, 2, 3]));
  const chatBodies = [];
  try {
    const chunks = await runAdapter(await adapterConnection(), store, version, async (url, init) => {
      const parsed = new URL(String(url));
      if (parsed.pathname === '/files') {
        return jsonResponse({ error: { message: 'files endpoint not found' } }, 404);
      }
      assert.equal(parsed.pathname, '/chat/completions');
      chatBodies.push(JSON.parse(init.body));
      return sseResponse();
    });
    assert.equal(chatBodies.length, 1);
    const parts = chatBodies[0].messages[0].content;
    assert.ok(parts.some((part) => part.type === 'image_url' && part.image_url.url === 'data:image/png;base64,AQID'));
    assert.equal(parts.some((part) => part.type === 'file'), false);
    assert.ok(chunks.some((chunk) => chunk.type === 'finish' && chunk.reason.kind === 'stop'));
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

await check('stale file id is invalidated and retried exactly once', async () => {
  const home = await mkdtemp('/tmp/dsh-rc2-stale-');
  const index = new DeepSeekUploadIndex(path.join(home, 'files-v3.json'));
  let uploadCount = 0;
  let chatCount = 0;
  const requests = [];
  const store = new DeepSeekFileStore({
    index,
    now: () => 1700000000000,
    fetch: async (url, init) => {
      const parsed = new URL(String(url));
      requests.push({ path: parsed.pathname, method: init?.method });
      if (parsed.pathname === '/files' && init?.method === 'POST') {
        uploadCount += 1;
        const file = init.body.get('file');
        const bytes = (await file.arrayBuffer()).byteLength;
        return jsonResponse(fileObject(uploadCount === 1 ? 'file-old' : 'file-new', bytes, 1700000000));
      }
      throw new Error(`unexpected file API request: ${parsed.pathname}`);
    },
  });
  const version = makeRequestVersion(new Uint8Array([9, 8, 7]), undefined, '3');
  try {
    const chunks = await runAdapter(await adapterConnection(), store, version, async (url, init) => {
      const parsed = new URL(String(url));
      if (parsed.pathname === '/files' && init?.method === 'POST') {
        uploadCount += 1;
        const file = init.body.get('file');
        const bytes = (await file.arrayBuffer()).byteLength;
        return jsonResponse(fileObject(uploadCount === 1 ? 'file-old' : 'file-new', bytes, 1700000000));
      }
      assert.equal(parsed.pathname, '/chat/completions');
      chatCount += 1;
      if (chatCount === 1) return jsonResponse({ error: { message: 'file file-old not found' } }, 400);
      return sseResponse('recovered');
    });
    assert.equal(chatCount, 2);
    assert.equal(uploadCount, 2);
    assert.ok(chunks.some((chunk) => chunk.type === 'finish' && chunk.reason.kind === 'stop'));
    const indexText = await readFile(index.path, 'utf8');
    assert.match(indexText, /file-new/);
    assert.doesNotMatch(indexText, /file-old/);
    assert.equal(requests.some((request) => request.method === 'DELETE'), false);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

await check('Files upload index is reused after store recreation', async () => {
  const home = await mkdtemp('/tmp/dsh-rc2-reuse-');
  const indexPath = path.join(home, 'files-v3.json');
  let uploadCount = 0;
  const version = makeRequestVersion(new Uint8Array([7, 7, 7]), undefined, '5');
  const scope = { baseURL: BASE_URL, apiKey: TEST_CREDENTIAL };
  const options = {
    expiresAfterSeconds: 3600,
    refreshMarginSeconds: 0,
    quotaCleanupBatch: 1,
  };
  try {
    const firstStore = new DeepSeekFileStore({
      index: new DeepSeekUploadIndex(indexPath),
      now: () => 1700000000000,
      fetch: async (url, init) => {
        assert.equal(new URL(String(url)).pathname, '/files');
        assert.equal(init.method, 'POST');
        uploadCount += 1;
        return jsonResponse(fileObject('file-reused', 3, 1700000000));
      },
    });
    const first = await firstStore.ensureUploaded(version, scope, options);
    assert.equal(first.uploaded, true);

    const recreatedStore = new DeepSeekFileStore({
      index: new DeepSeekUploadIndex(indexPath),
      now: () => 1700000000000,
      fetch: async () => {
        throw new Error('persisted upload index was not reused');
      },
    });
    const reused = await recreatedStore.ensureUploaded(version, scope, options);
    assert.equal(reused.uploaded, false);
    assert.equal(String(reused.record.fileId), 'file-reused');
    assert.equal(uploadCount, 1);
    assert.doesNotMatch(await readFile(indexPath, 'utf8'), new RegExp(TEST_CREDENTIAL));
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

await check('quota cleanup deletes only the oldest harness-owned dsh-* file', async () => {
  const home = await mkdtemp('/tmp/dsh-rc2-quota-');
  const deleted = [];
  let uploadCount = 0;
  const files = [
    fileObject('foreign-old', 1, 1, 'user-image.png'),
    fileObject('dsh-old', 1, 2, 'dsh-old.png'),
    fileObject('dsh-new', 1, 3, 'dsh-new.png'),
    fileObject('foreign-new', 1, 4, 'other.png'),
  ];
  const fetchImpl = async (url, init = {}) => {
    const parsed = new URL(String(url));
    if (parsed.pathname === '/files' && init.method === 'GET') return listResponse(files);
    if (parsed.pathname.startsWith('/files/') && init.method === 'DELETE') {
      deleted.push(parsed.pathname.slice('/files/'.length));
      return jsonResponse({ id: parsed.pathname.slice('/files/'.length), object: 'file', deleted: true });
    }
    if (parsed.pathname === '/files' && init.method === 'POST') {
      uploadCount += 1;
      if (uploadCount === 1) return jsonResponse({ error: { message: 'storage quota exceeded' } }, 429);
      const file = init.body.get('file');
      return jsonResponse(fileObject('dsh-recovered', (await file.arrayBuffer()).byteLength, 10, 'dsh-recovered.png'));
    }
    throw new Error(`unexpected quota request: ${parsed.pathname} ${init.method}`);
  };
  const store = new DeepSeekFileStore({
    index: new DeepSeekUploadIndex(path.join(home, 'files-v3.json')),
    now: () => 1700000000000,
    fetch: fetchImpl,
  });
  const version = makeRequestVersion(new Uint8Array([4, 5, 6]), undefined, '4');
  try {
    const result = await store.ensureUploaded(version, { baseURL: BASE_URL, apiKey: TEST_CREDENTIAL }, {
      expiresAfterSeconds: 3600,
      refreshMarginSeconds: 0,
      quotaCleanupBatch: 1,
    });
    assert.equal(result.uploaded, true);
    assert.equal(String(result.record.fileId), 'dsh-recovered');
    assert.equal(uploadCount, 2);
    assert.deepEqual(deleted, ['dsh-old']);
    const indexText = await readFile(path.join(home, 'files-v3.json'), 'utf8');
    assert.doesNotMatch(indexText, new RegExp(TEST_CREDENTIAL));
    assert.match(indexText, /^[\s\S]*"scope": "[0-9a-f]{64}"/);
    assert.notEqual(String(deepSeekFileScope(BASE_URL, TEST_CREDENTIAL)), TEST_CREDENTIAL);

    const logs = [];
    const previousError = console.error;
    const previousWarn = console.warn;
    console.error = (...args) => logs.push(args.join(' '));
    console.warn = (...args) => logs.push(args.join(' '));
    try {
      const failingClient = new DeepSeekFilesClient({
        baseURL: BASE_URL,
        apiKey: TEST_CREDENTIAL,
        fetch: async () => { throw new Error('offline mock transport'); },
      });
      await assert.rejects(failingClient.list(), (error) => {
        assert.doesNotMatch(String(error), new RegExp(TEST_CREDENTIAL));
        assert.doesNotMatch(String(error?.stack ?? ''), new RegExp(TEST_CREDENTIAL));
        return true;
      });
    } finally {
      console.error = previousError;
      console.warn = previousWarn;
    }
    assert.doesNotMatch(logs.join('\n'), new RegExp(TEST_CREDENTIAL));
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

if (failures > 0) {
  console.error(`FAIL: rc.2 regression (${failures} failed, ${passes} passed)`);
  process.exitCode = 1;
} else {
  console.log(`PASS: rc.2 regression (${passes} contracts)`);
}
