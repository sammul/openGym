// The iPhone end of the Apple Watch companion (docs/APPLE_WATCH.md). What to send and what a
// message means are lib/watch.js; this file moves them through the native Watch plugin
// (ios/App/App/WatchPlugin.swift) and writes what they mean into the store.
//
// Phone → watch: the pack (every session the watch can run on its own, sent as a file so its
// size does not matter, whenever the plan or the history it is built from changes) and the live
// snapshot (the workout running here and its rest, whenever either changes).
// Watch → phone: commands, kept by the native side in an inbox file until this side has applied
// them and said so (ack). The WebView may be asleep when the watch speaks; nothing is lost
// meanwhile, and on the next launch or return to the foreground the inbox is read again.
import { useStore } from '../store/useStore.js'
import { useUI } from '../store/useUI.js'
import { MOBILE, isIOS, onAppActive } from './mobile.js'
import { buildWatchPack, buildLiveSnapshot, applySetPatch, prepareWatchSession, rememberCommand, restAction } from './watch.js'
import { finishWorkoutFromWatch, commitWatchSession } from '../sheets.jsx'

const SEEN_KEY = 'gym_watch_seen'
const PACK_DEBOUNCE_MS = 4000
const LIVE_DEBOUNCE_MS = 250

const readSeen = () => { try { return JSON.parse(localStorage.getItem(SEEN_KEY) || '[]') } catch { return [] } }
const writeSeen = list => { try { localStorage.setItem(SEEN_KEY, JSON.stringify(list)) } catch { /* counted again, applied idempotently anyway */ } }

// In an object, never as the bare proxy: a Capacitor plugin proxy answers `then` with a native
// call that never settles (see lib/rest-alert.js restPlugin).
let pluginP = null
const watchPlugin = () => pluginP || (pluginP = (async () => {
  if (!(await isIOS())) return null
  const { registerPlugin } = await import('@capacitor/core')
  return { Watch: registerPlugin('Watch') }
})().catch(() => null))

let started = false
export function initWatchBridge() {
  if (!MOBILE || started) return
  started = true
  watchPlugin().then(p => {
    if (!p) return
    const { Watch } = p
    let packTm = null, liveTm = null
    let packKey = null, liveKey = null

    const sendPack = () => {
      packTm = null
      const json = JSON.stringify(buildWatchPack(useStore.getState().S))
      Watch.sendPack({ json }).catch(() => {})
    }
    const sendLive = () => {
      liveTm = null
      const snap = buildLiveSnapshot(useStore.getState().S, useUI.getState().timer, { seen: readSeen().slice(-50) })
      Watch.sendLive({ json: JSON.stringify(snap) }).catch(() => {})
    }
    // What the pack is built from. Comparing references is enough: every store write replaces
    // what it touched (useStore update clones).
    const packInputs = S => [S.routines, S.workouts, S.week, S.dayPlan, S.queue, S.rotation, S.unit, S.restSec, S.lang, S.exWeights, S.customEx]
    const sameList = (a, b) => a && b && a.length === b.length && a.every((x, k) => x === b[k])

    useStore.subscribe(state => {
      const S = state.S
      const pk = packInputs(S)
      if (!sameList(pk, packKey)) { packKey = pk; clearTimeout(packTm); packTm = setTimeout(sendPack, PACK_DEBOUNCE_MS) }
      if (S.active !== liveKey) { liveKey = S.active; clearTimeout(liveTm); liveTm = setTimeout(sendLive, LIVE_DEBOUNCE_MS) }
    })
    let timerKey = useUI.getState().timer
    useUI.subscribe(state => {
      if (state.timer === timerKey) return
      timerKey = state.timer
      clearTimeout(liveTm); liveTm = setTimeout(sendLive, LIVE_DEBOUNCE_MS)
    })

    let draining = null
    const drain = () => draining || (draining = (async () => {
      try {
        const { items = [] } = await Watch.drain()
        const done = []
        for (const item of items) {
          let msg = null
          try { msg = JSON.parse(item.json) } catch { /* unreadable: dropped below */ }
          if (handle(msg, { sendPack, sendLive })) done.push(item.key)
        }
        if (done.length) await Watch.ack({ keys: done })
      } catch { /* read again on the next event or return to the foreground */ } finally { draining = null }
    })())

    Watch.addListener('inbox', () => { drain() }).catch(() => {})
    onAppActive(() => { drain(); sendLive() })
    drain()
    sendPack()
    sendLive()
  })
}

// Applies one message from the watch. True once it is dealt with (applied, or not worth keeping),
// false to leave it in the inbox for later: a session the watch ran alone, while a workout is
// running here.
export function handle(msg, { sendPack, sendLive } = {}) {
  if (!msg || typeof msg !== 'object' || typeof msg.type !== 'string') return true
  if (msg.type === 'hello') { sendPack?.(); sendLive?.(); return true }
  const seen = readSeen()
  if (msg.id && seen.includes(msg.id)) return true
  const S = useStore.getState().S
  const mine = S.active && S.active.id === msg.sid && !S.active.editingWorkoutId && !S.active.backfill
  let applied = true
  switch (msg.type) {
    case 'set': {
      if (!mine) break
      const next = applySetPatch(S.active.entries, msg)
      if (next) useStore.getState().update(s => { s.active.entries = next })
      break
    }
    case 'rest': {
      if (!mine) break
      const act = restAction(msg)
      const ui = useUI.getState()
      if (!act) break
      if (act.op === 'start') ui.startRest(act.sec)
      else if (act.op === 'add') ui.addRest(act.sec)
      else if (act.op === 'skip') ui.stopRest()
      else if (act.op === 'pause') ui.pauseRest()
      else if (act.op === 'resume') ui.resumeRest()
      break
    }
    case 'cur': {
      if (mine && Number.isInteger(msg.cur) && msg.cur >= 0 && msg.cur < S.active.entries.length) useStore.getState().update(s => { s.active.cur = msg.cur })
      break
    }
    case 'finish': {
      if (mine) finishWorkoutFromWatch(msg.sid)
      break
    }
    case 'session': {
      // Already saved: the id of the workout it became is the session's own.
      if (S.workouts.some(w => w.id === msg.sid)) break
      const A = prepareWatchSession(msg)
      if (!A) break
      applied = commitWatchSession(A)
      break
    }
    default: break
  }
  if (applied && msg.id) { const next = rememberCommand(seen, msg.id); if (next) writeSeen(next) }
  return applied
}
