// asana-api.js — Thin wrapper around the Asana REST API.
// Token source: ~/.config/agent-watcher/credentials.json (asana_token).
// Used by both the kanban setup and the watcher.

const fs = require('node:fs')
const path = require('node:path')
const { execSync } = require('node:child_process')

const HOME = process.env.HOME || ''
const CRED_FILE = path.join(HOME, '.config/agent-watcher/credentials.json')
const API_BASE = 'https://app.asana.com/api/1.0'

function getToken() {
  if (process.env.ASANA_TOKEN) return process.env.ASANA_TOKEN
  try {
    const data = JSON.parse(fs.readFileSync(CRED_FILE, 'utf8'))
    if (data.asana_token) return data.asana_token
  } catch {}
  throw new Error(`ASANA_TOKEN not set and no token in ${CRED_FILE}`)
}

const TOKEN = getToken()

function request(method, endpoint, body) {
  const url = endpoint.startsWith('http') ? endpoint : `${API_BASE}${endpoint}`
  const args = [
    '-sS',
    '-X', method,
    '-H', `Authorization: Bearer ${TOKEN}`,
    '-H', 'Content-Type: application/json',
    '-H', 'Accept: application/json',
    '-w', '\n%{http_code}',
  ]
  if (body !== undefined) {
    args.push('-d', JSON.stringify(body))
  }
  args.push(url)

  let raw
  try {
    raw = execSync(`curl ${args.map((a) => `'${a.replace(/'/g, "'\\''")}'`).join(' ')}`, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      maxBuffer: 10 * 1024 * 1024,
    })
  } catch (err) {
    throw new Error(`curl failed for ${method} ${endpoint}: ${err.message}`)
  }

  const lastNewline = raw.lastIndexOf('\n')
  const codeStr = raw.slice(lastNewline + 1).trim()
  const bodyStr = raw.slice(0, lastNewline)
  const code = parseInt(codeStr, 10)

  let parsed
  try { parsed = JSON.parse(bodyStr) } catch { parsed = { raw: bodyStr } }

  if (code < 200 || code >= 300) {
    const errMsg = parsed?.errors?.map((e) => e.message).join('; ') || bodyStr
    throw new Error(`Asana ${method} ${endpoint} -> ${code}: ${errMsg}`)
  }
  return parsed
}

// ─── Convenience wrappers ────────────────────────────────────────────────────

function getMe() {
  return request('GET', '/users/me').data
}

function getWorkspaces() {
  return request('GET', '/workspaces').data
}

function getProject(projectGid) {
  return request('GET', `/projects/${projectGid}`).data
}

function listProjectTasks(projectGid, optFields) {
  const q = optFields ? `?opt_fields=${encodeURIComponent(optFields)}` : ''
  return request('GET', `/projects/${projectGid}/tasks${q}`).data
}

function getTask(taskGid, optFields) {
  const q = optFields ? `?opt_fields=${encodeURIComponent(optFields)}` : ''
  return request('GET', `/tasks/${taskGid}${q}`).data
}

function updateTask(taskGid, fields) {
  return request('PUT', `/tasks/${taskGid}`, { data: fields }).data
}

function createCustomField(workspaceGid, body) {
  return request('POST', '/custom_fields', { data: { workspace: workspaceGid, ...body } }).data
}

function addCustomFieldToProject(projectGid, customFieldGid) {
  return request('POST', `/projects/${projectGid}/addCustomFieldSetting`, {
    data: { custom_field: customFieldGid },
  }).data
}

module.exports = {
  request,
  getMe,
  getWorkspaces,
  getProject,
  listProjectTasks,
  getTask,
  updateTask,
  createCustomField,
  addCustomFieldToProject,
  API_BASE,
}
