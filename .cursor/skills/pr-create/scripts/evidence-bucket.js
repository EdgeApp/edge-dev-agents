#!/usr/bin/env node
// evidence-bucket.js: the evidence path's client for the orch asset bucket
// (Cloudflare R2 over the S3 API). Run it through evidence-bucket.sh.
//
// One bucket holds every evidence frame and every per-PR manifest, and all of
// it is public by URL. Nothing private may be stored here: frames pass
// evidence-privacy.sh before pr-attach-screenshots.sh uploads them.
//
//   check                               exit 0 when the bucket is configured
//   put <file> <key>                    upload, print the object's public URL
//   get <key> [<out>]                   object bytes to <out>, or to stdout
//   exists <key>                        exit 0 when the object exists
//   delete <key>                        remove the object (absent is not an error)
//   list [<prefix>]                     one key per line
//   url <key>                           print the public URL, no request made
//   manifest-key <owner/repo> <pr>      print the manifest's object key
//   manifest-get <owner/repo> <pr> [<out>]
//   manifest-put <owner/repo> <pr> <file>
//
// A PR's manifest lives at manifests/<owner>/<repo>/pr-<num>.json. The key is
// predictable on purpose: a manifest names scenes, batches and frame URLs, and
// every one of those is already in the PR body.
//
// Config: the same file site-orch's upload-asset.sh reads,
// ${SITE_ORCH_SECRETS:-~/.config/site-orch/secrets}/r2.json, holding
// { accountId, accessKeyId, secretAccessKey, bucket, publicBaseUrl }.
// EVIDENCE_BUCKET_CONFIG names another file; an `endpoint` field in it replaces
// the R2 host (tests point it at a local server).
//
// Exit codes: 0 ok; 1 bad usage, no config, or a failed request; 4 the object
// does not exist (get, exists, manifest-get). A caller that reads a manifest
// must tell 4 from 1: "no manifest yet" starts an empty table, a failed read
// must stop the run before it overwrites the table it could not read.

'use strict'

const crypto = require('crypto')
const fs = require('fs')
const http = require('http')
const https = require('https')
const os = require('os')
const path = require('path')

const NOT_FOUND = 4

const TYPES = {
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif',
  '.webp': 'image/webp', '.mp4': 'video/mp4', '.json': 'application/json', '.txt': 'text/plain'
}

function configPath() {
  return process.env.EVIDENCE_BUCKET_CONFIG ||
    path.join(process.env.SITE_ORCH_SECRETS || path.join(os.homedir(), '.config/site-orch/secrets'), 'r2.json')
}

function loadConfig() {
  const file = configPath()
  let cfg
  try { cfg = JSON.parse(fs.readFileSync(file, 'utf8')) } catch (e) { throw new Error(`no asset bucket configured (${file}): ${e.message}`) }
  for (const k of ['accessKeyId', 'secretAccessKey', 'bucket', 'publicBaseUrl']) {
    if (typeof cfg[k] !== 'string' || cfg[k] === '') throw new Error(`asset bucket config ${file} has no ${k}`)
  }
  if (!cfg.endpoint && !cfg.accountId) throw new Error(`asset bucket config ${file} has no accountId`)
  return cfg
}

function cleanKey(key) {
  const k = String(key || '').replace(/^\/+/, '')
  if (k === '' || k.endsWith('/')) throw new Error(`bad object key '${key}'`)
  return k
}

function manifestKey(repo, pr) {
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo || '')) throw new Error(`bad repo '${repo}': want owner/repo`)
  if (!/^\d+$/.test(String(pr))) throw new Error(`bad PR number '${pr}'`)
  return `manifests/${repo}/pr-${pr}.json`
}

const publicUrl = (cfg, key) => `${cfg.publicBaseUrl.replace(/\/+$/, '')}/${cleanKey(key)}`

// RFC 3986 encoding, which is what SigV4 signs: encodeURIComponent leaves
// ! * ' ( ) bare.
const enc = s => encodeURIComponent(s).replace(/[!*'()]/g, c => '%' + c.charCodeAt(0).toString(16).toUpperCase())
const sha256 = d => crypto.createHash('sha256').update(d).digest('hex')
const hmac = (k, d) => crypto.createHmac('sha256', k).update(d).digest()

// One signed S3 request. Resolves { status, body } for every HTTP answer;
// rejects only when no answer arrived.
function request(cfg, method, key, { body = Buffer.alloc(0), query = {}, contentType } = {}) {
  const endpoint = new URL(cfg.endpoint || `https://${cfg.accountId}.r2.cloudflarestorage.com`)
  const uri = '/' + enc(cfg.bucket) + (key ? '/' + key.split('/').map(enc).join('/') : '')
  const queryString = Object.keys(query).sort().map(k => `${enc(k)}=${enc(query[k])}`).join('&')
  const amzDate = new Date().toISOString().replace(/[:-]|\.\d{3}/g, '')
  const day = amzDate.slice(0, 8)
  const payloadHash = sha256(body)
  const headers = { host: endpoint.host, 'x-amz-content-sha256': payloadHash, 'x-amz-date': amzDate }
  if (contentType) headers['content-type'] = contentType
  const names = Object.keys(headers).sort()
  const canonical = [method, uri, queryString, names.map(n => `${n}:${headers[n]}\n`).join(''), names.join(';'), payloadHash].join('\n')
  const scope = `${day}/auto/s3/aws4_request`
  const toSign = ['AWS4-HMAC-SHA256', amzDate, scope, sha256(canonical)].join('\n')
  const signingKey = hmac(hmac(hmac(hmac('AWS4' + cfg.secretAccessKey, day), 'auto'), 's3'), 'aws4_request')
  const signature = crypto.createHmac('sha256', signingKey).update(toSign).digest('hex')
  headers.authorization = `AWS4-HMAC-SHA256 Credential=${cfg.accessKeyId}/${scope}, SignedHeaders=${names.join(';')}, Signature=${signature}`
  if (body.length > 0 || method === 'PUT') headers['content-length'] = body.length

  return new Promise((resolve, reject) => {
    const lib = endpoint.protocol === 'http:' ? http : https
    const req = lib.request({
      host: endpoint.hostname, port: endpoint.port || undefined, method, headers,
      path: uri + (queryString ? '?' + queryString : '')
    }, res => {
      const chunks = []
      res.on('data', c => chunks.push(c))
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks) }))
    })
    req.setTimeout(60000, () => req.destroy(new Error('timed out after 60s')))
    req.on('error', reject)
    req.end(body)
  })
}

const ok = r => r.status >= 200 && r.status < 300
const httpError = (what, r) => new Error(`${what}: HTTP ${r.status} ${r.body.toString('utf8').slice(0, 300)}`)

async function put(cfg, file, key) {
  key = cleanKey(key)
  const contentType = TYPES[path.extname(key).toLowerCase()] || 'application/octet-stream'
  const r = await request(cfg, 'PUT', key, { body: fs.readFileSync(file), contentType })
  if (!ok(r)) throw httpError(`upload of ${key} failed`, r)
  return publicUrl(cfg, key)
}

// The object's bytes, or null when it does not exist.
async function get(cfg, key) {
  key = cleanKey(key)
  const r = await request(cfg, 'GET', key)
  if (r.status === 404) return null
  if (!ok(r)) throw httpError(`read of ${key} failed`, r)
  return r.body
}

async function exists(cfg, key) {
  key = cleanKey(key)
  const r = await request(cfg, 'HEAD', key)
  if (r.status === 404) return false
  if (!ok(r)) throw httpError(`lookup of ${key} failed`, r)
  return true
}

async function del(cfg, key) {
  key = cleanKey(key)
  const r = await request(cfg, 'DELETE', key)
  if (!ok(r) && r.status !== 404) throw httpError(`delete of ${key} failed`, r)
}

const unxml = s => s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&')

async function list(cfg, prefix) {
  const keys = []
  let token = null
  do {
    const query = { 'list-type': '2' }
    if (prefix) query.prefix = prefix
    if (token) query['continuation-token'] = token
    const r = await request(cfg, 'GET', '', { query })
    if (!ok(r)) throw httpError('list failed', r)
    const xml = r.body.toString('utf8')
    for (const m of xml.matchAll(/<Key>([^<]*)<\/Key>/g)) keys.push(unxml(m[1]))
    const next = xml.match(/<NextContinuationToken>([^<]*)<\/NextContinuationToken>/)
    token = /<IsTruncated>true<\/IsTruncated>/.test(xml) && next ? unxml(next[1]) : null
  } while (token)
  return keys
}

function writeOut(bytes, out) {
  if (!out) { process.stdout.write(bytes); return }
  // A rename is atomic, so a reader never sees half an object.
  const tmp = `${out}.part-${process.pid}`
  fs.writeFileSync(tmp, bytes)
  fs.renameSync(tmp, out)
}

async function main(argv) {
  const [cmd, ...args] = argv
  const need = n => { if (args.length < n) throw Object.assign(new Error(`${cmd}: missing argument (see the header of evidence-bucket.js)`), { usage: true }) }
  if (cmd === 'check') {
    try { loadConfig() } catch (e) { return 1 }
    return 0
  }
  if (cmd === 'manifest-key') { need(2); console.log(manifestKey(args[0], args[1])); return 0 }
  const cfg = loadConfig()
  switch (cmd) {
    case 'url': need(1); console.log(publicUrl(cfg, args[0])); return 0
    case 'put': need(2); console.log(await put(cfg, args[0], args[1])); return 0
    case 'get': case 'manifest-get': {
      need(cmd === 'get' ? 1 : 2)
      const key = cmd === 'get' ? args[0] : manifestKey(args[0], args[1])
      const bytes = await get(cfg, key)
      if (bytes == null) { process.stderr.write(`no such object: ${key}\n`); return NOT_FOUND }
      if (cmd === 'manifest-get') JSON.parse(bytes.toString('utf8'))
      writeOut(bytes, cmd === 'get' ? args[1] : args[2])
      return 0
    }
    case 'manifest-put': {
      need(3)
      const man = JSON.parse(fs.readFileSync(args[2], 'utf8'))
      if (man == null || !Array.isArray(man.entries)) throw new Error(`${args[2]} is not a manifest: it has no entries array`)
      console.log(await put(cfg, args[2], manifestKey(args[0], args[1])))
      return 0
    }
    case 'exists': need(1); return (await exists(cfg, args[0])) ? 0 : NOT_FOUND
    case 'delete': need(1); await del(cfg, args[0]); return 0
    case 'list': for (const k of await list(cfg, args[0])) console.log(k); return 0
    default:
      process.stderr.write('usage: evidence-bucket.sh check|put|get|exists|delete|list|url|manifest-key|manifest-get|manifest-put ... (see the header of evidence-bucket.js)\n')
      return 1
  }
}

if (require.main === module) {
  main(process.argv.slice(2)).then(code => { process.exitCode = code }, e => {
    process.stderr.write(`evidence-bucket: ${e.message}\n`)
    process.exitCode = 1
  })
}

module.exports = { manifestKey, publicUrl }
