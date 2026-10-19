// The Apple Watch companion (docs/APPLE_WATCH.md): what the phone sends the watch, and what it
// does with what comes back. Pure: lib/watch-bridge.js does the sending and the store writes.
//
// The watch has no training logic of its own. The phone builds every session it might run with
// the same code a session started on the phone uses (session-merge.js buildCombinedEntries), so
// the weights on the wrist are the progression engine's, and lays out the order the sets come in
// and the rest after each one. The watch walks that list and sends back patches: "set 2 of the
// squat: 100 × 5, done at 18:04". The phone applies them with applySetPatch, whether they arrive
// one by one during a workout started on the phone, or all together with a session the watch ran
// on its own (prepareWatchSession), which then takes the ordinary finish path.
import { EXIDX } from './exercises.js'
import { t, exerciseNameFor } from './i18n-core.js'
import { buildCombinedEntries, deriveSessionName } from './session-merge.js'
import { effectiveRoutineIds, modeOf, supersetUnits } from './history.js'
import { isWarmupRow, isSideSet, setSideField, setType } from './workout-model.js'
import { restSecFor, warmupRestSecFor } from './supersetFlow.js'
import { weightIncrement, DEFAULT_SEC_INCREMENT } from './progression.js'
import { todayISO } from './format.js'

export const WATCH_PROTOCOL = 1
// A pack is every session the watch can start on its own; past this many routines it is the
// first ones in the list (today's first), which is more than a wrist can scroll through anyway.
export const WATCH_PACK_MAX = 12

const num = v => (typeof v === 'number' && Number.isFinite(v) ? v : null)
const nonNeg = v => { const n = num(v); return n != null && n >= 0 ? n : null }

function exerciseName(id) {
  const ex = EXIDX[id]
  return ex ? exerciseNameFor(ex) : String(id ?? '')
}

// What the watch shows of one row. Per-side reps rows carry both sides; a timed hold done per
// side is two rows already, each with its `side`.
export function watchSetView(set) {
  const s = set || {}
  const out = { done: !!s.done }
  for (const k of ['w', 'r', 'sec', 'min']) if (num(s[k]) != null) out[k] = s[k]
  if (isWarmupRow(s)) out.warm = true
  if (s.side === 'L' || s.side === 'R') out.side = s.side
  if (isSideSet(s)) out.sides = { L: sideView(s.sides.L), R: sideView(s.sides.R) }
  const type = setType(s)
  if (type !== 'straight') out.type = type
  return out
}
const sideView = x => ({ w: num(x?.w) ?? 0, r: num(x?.r) ?? 0, done: !!x?.done })

/**
 * One session laid out for the watch: each entry's name, mode and sets, and `order`, the steps in
 * the order the workout screen would walk them. A superset goes round by round (A1 B1 A2 B2), with
 * no rest between the members of a round. `rest` is the seconds to rest after that step, the same
 * figures the phone's rest timer would start (supersetFlow.js); the last step rests 0.
 */
export function watchSessionView(S, entries) {
  const list = Array.isArray(entries) ? entries : []
  const unit = S?.unit === 'lb' ? 'lb' : 'kg'
  const units = supersetUnits(list)
  const view = list.map((e, idx) => {
    const mode = modeOf(e?.target || { id: e?.id })
    const step = mode === 'time' ? DEFAULT_SEC_INCREMENT : mode === 'cardio' ? 1 : weightIncrement(e?.target || { id: e?.id }, unit)
    return { idx, id: e?.id, name: exerciseName(e?.id), mode, step, ...(e?.sg ? { sg: e.sg } : {}), sets: (e?.sets || []).map(watchSetView) }
  })
  const order = []
  for (const u of units) {
    const unitRest = restSecFor(list, u, S?.restSec)
    if (u.length === 1) {
      const e = list[u[0]]
      ;(e?.sets || []).forEach((_, i) => order.push({ e: u[0], i, rest: warmupRestSecFor(e, i, unitRest) }))
      continue
    }
    const rounds = Math.max(...u.map(ix => list[ix]?.sets?.length || 0))
    for (let r = 0; r < rounds; r++) {
      const members = u.filter(ix => (list[ix]?.sets?.length || 0) > r)
      members.forEach((ix, k) => order.push({ e: ix, i: r, rest: k === members.length - 1 ? unitRest : 0 }))
    }
  }
  if (order.length) order[order.length - 1].rest = 0
  return { unit, entries: view, order }
}

/**
 * Everything the watch can start without the phone: today's routines as one session, then each
 * routine with exercises in it. Each session carries its view and `raw`, the entries exactly as
 * the phone would have started them, as JSON text the watch keeps unread and hands back.
 */
export function buildWatchPack(S, { now = Date.now(), today = todayISO() } = {}) {
  const routines = (S?.routines || []).filter(r => r && Array.isArray(r.ex) && r.ex.length)
  const sessions = []
  const add = (key, ids, isToday) => {
    const { entries, routineIds, routines: rs } = buildCombinedEntries(S, ids)
    if (!entries.length) return
    const name = deriveSessionName(rs.map(r => r.name || '')) || t('Workout')
    sessions.push({ key, rids: routineIds, name, ...(isToday ? { today: true } : {}), ...watchSessionView(S, entries), raw: JSON.stringify(entries) })
  }
  const todays = effectiveRoutineIds(S, today).filter(id => routines.some(r => r.id === id))
  if (todays.length) add('today', todays, true)
  for (const r of routines) {
    if (sessions.length >= WATCH_PACK_MAX) break
    // Today's single routine is already the first session.
    if (todays.length === 1 && todays[0] === r.id) continue
    add(r.id, [r.id], false)
  }
  return { v: WATCH_PROTOCOL, kind: 'pack', built: now, unit: S?.unit === 'lb' ? 'lb' : 'kg', labels: watchLabels(), sessions }
}

/**
 * The workout running on the phone, for the watch to follow and drive; null when there is none (or
 * when S.active is an edit of a saved workout or a past one being logged, which the watch leaves
 * alone). `seen` is the ids of the latest watch commands applied, so the watch can tell which of
 * its own changes this copy already has.
 */
export function buildLiveSnapshot(S, timer, { seen = [], now = Date.now() } = {}) {
  const A = S?.active
  if (!A || A.editingWorkoutId || A.backfill) return { v: WATCH_PROTOCOL, kind: 'live', at: now, active: null, seen }
  const rest = timer && !timer.ready && timer.kind !== 'work'
    ? { endsAt: timer.endsAt, total: timer.total, ...(timer.paused ? { paused: true, left: timer.left } : {}), ...(timer.kind === 'switch' ? { kind: 'switch' } : {}) }
    : null
  return {
    v: WATCH_PROTOCOL, kind: 'live', at: now, seen,
    active: { sid: A.id, name: A.name || t('Workout'), start: A.start, cur: A.cur || 0, ...watchSessionView(S, A.entries), rest },
  }
}

/**
 * One change from the watch to one row of a session: `{ e, x, i, w?, r?, sec?, min?, done?, side?,
 * at? }`. `x` is the exercise id the watch saw at index `e`; when the phone's list has moved since
 * (an exercise added or swapped there), the patch follows the exercise, and is dropped when it is
 * gone. Returns the new entries array, or null when nothing applied. A row that is not there is
 * not made up: the watch only ever patches rows it was sent.
 */
export function applySetPatch(entries, patch, now = Date.now()) {
  if (!Array.isArray(entries) || !patch || typeof patch !== 'object') return null
  let e = Number.isInteger(patch.e) ? patch.e : -1
  if (patch.x != null && entries[e]?.id !== patch.x) e = entries.findIndex(en => en?.id === patch.x)
  const entry = entries[e]
  const i = Number.isInteger(patch.i) ? patch.i : -1
  const row = entry?.sets?.[i]
  if (!row) return null
  let next = { ...row }
  const at = num(patch.at) ?? now
  if (isSideSet(next)) {
    const sides = patch.side === 'L' || patch.side === 'R' ? [patch.side] : ['L', 'R']
    for (const side of sides) {
      for (const k of ['w', 'r']) if (nonNeg(patch[k]) != null) next = setSideField(next, side, k, patch[k])
      // Values for one side given per side: { sides: { L: { r }, R: { r } } }
      const own = patch.sides?.[side]
      if (own) for (const k of ['w', 'r']) if (nonNeg(own[k]) != null) next = setSideField(next, side, k, own[k])
      if (typeof patch.done === 'boolean') next = setSideField(next, side, 'done', patch.done)
    }
  } else {
    for (const k of ['w', 'r', 'sec', 'min']) if (nonNeg(patch[k]) != null) next[k] = patch[k]
    if (typeof patch.done === 'boolean') next.done = patch.done
  }
  if (patch.done === true) {
    next.at = at
    delete next.planSec
  }
  const sets = entry.sets.slice()
  sets[i] = next
  const out = entries.slice()
  out[e] = { ...entry, sets }
  return out
}

/**
 * A session the watch ran on its own, turned back into the `S.active` the phone would have had:
 * the entries it was started with (`raw`, as the pack sent them) with the watch's patches applied
 * in order. Null when there is nothing to save: unreadable entries, or not one set done.
 */
export function prepareWatchSession(msg, { now = Date.now() } = {}) {
  if (!msg || typeof msg !== 'object') return null
  let entries
  try { entries = typeof msg.raw === 'string' ? JSON.parse(msg.raw) : msg.raw } catch { return null }
  if (!Array.isArray(entries) || !entries.length || entries.some(e => !e || typeof e !== 'object' || !Array.isArray(e.sets))) return null
  for (const p of Array.isArray(msg.patches) ? msg.patches : []) {
    const next = applySetPatch(entries, p, now)
    if (next) entries = next
  }
  if (!entries.some(e => e.sets.some(s => s.done))) return null
  const start = num(msg.start) ?? now
  return {
    id: typeof msg.sid === 'string' && msg.sid ? msg.sid : String(start),
    d: isoDay(start),
    start,
    routineIds: Array.isArray(msg.rids) ? msg.rids.filter(id => typeof id === 'string') : [],
    name: typeof msg.name === 'string' && msg.name ? msg.name : t('Workout'),
    bw: null, cur: 0, entries,
    fromWatch: true,
    ...(num(msg.end) > start ? { end: msg.end } : {}),
  }
}

const isoDay = ms => {
  const d = new Date(ms)
  return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0')
}

/**
 * Command ids the phone has applied, newest last, so one that arrives twice (sent live and also
 * queued, or redelivered after the phone restarted) counts once. Returns the new list, or null
 * when `id` is already in it.
 */
export const WATCH_SEEN_MAX = 300
export function rememberCommand(seen, id) {
  const list = Array.isArray(seen) ? seen : []
  if (typeof id !== 'string' || !id) return list
  if (list.includes(id)) return null
  const out = [...list, id]
  return out.length > WATCH_SEEN_MAX ? out.slice(out.length - WATCH_SEEN_MAX) : out
}

// What the rest timer should do for a `rest` command, given when the watch sent it: a rest the
// watch started 4 s ago in a 90 s rest has 86 s left on the phone. Null when there is nothing to do.
export function restAction(cmd, now = Date.now()) {
  if (!cmd || typeof cmd !== 'object') return null
  switch (cmd.op) {
    case 'start': {
      const sec = nonNeg(cmd.sec)
      if (!sec) return null
      const elapsed = Math.max(0, Math.round((now - (num(cmd.at) ?? now)) / 1000))
      const left = sec - elapsed
      return left > 0 ? { op: 'start', sec: left } : null
    }
    case 'add': return num(cmd.sec) ? { op: 'add', sec: cmd.sec } : null
    case 'skip': case 'pause': case 'resume': return { op: cmd.op }
    default: return null
  }
}

// The watch's own words, in the phone's language. The watch falls back to English for any it lacks.
export function watchLabels() {
  return {
    start: t('Start'), done: t('Done'), rest: t('Rest'), skip: t('Skip'), finish: t('Finish'),
    setOf: t('Set {0} of {1}'), warmup: t('Warm-up'), next: t('Next'), today: t('Today'),
    reps: t('reps'), left: t('L'), right: t('R'),
    restOver: t('Rest’s over. Next set!'),
    finishAsk: t('Finish workout?'), saved: t('Saved. It goes to your iPhone when it is in range.'),
    onPhone: t('Workout on your iPhone'), noPack: t('Open openGym on your iPhone once to send your routines.'),
    allDone: t('All sets done'),
  }
}
