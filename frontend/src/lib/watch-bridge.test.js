// What the phone does with each message from the watch (lib/watch-bridge.js handle). The store,
// the rest timer and the finish path are stand-ins; what a patch does to a row is watch.test.js.
import { beforeEach, describe, expect, it, vi } from 'vitest'

const h = vi.hoisted(() => {
  const store = new Map()
  vi.stubGlobal('localStorage', { getItem: k => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, String(v)), clear: () => store.clear() })
  return { S: null, ui: null, finished: [], committed: [], commitOk: true }
})

vi.mock('../store/useStore.js', () => ({
  useStore: { getState: () => ({ S: h.S, update: fn => { const next = JSON.parse(JSON.stringify(h.S)); fn(next); h.S = next } }), subscribe: () => {} },
}))
vi.mock('../store/useUI.js', () => ({ useUI: { getState: () => h.ui, subscribe: () => {} } }))
vi.mock('../sheets.jsx', () => ({
  finishWorkoutFromWatch: sid => { h.finished.push(sid); return true },
  commitWatchSession: A => { h.committed.push(A); return h.commitOk },
}))

const { handle } = await import('./watch-bridge.js')

const row = () => ({ w: 60, r: 5, done: false })
const active = () => ({ id: 'w1', name: 'Strength', start: 1, cur: 0, entries: [{ id: '0025', sets: [row(), row()] }] })

beforeEach(() => {
  localStorage.clear()
  h.S = { workouts: [], active: active() }
  h.ui = { startRest: vi.fn(), addRest: vi.fn(), stopRest: vi.fn(), pauseRest: vi.fn(), resumeRest: vi.fn() }
  h.finished = []; h.committed = []; h.commitOk = true
})

describe('a set from the watch', () => {
  it('lands on the workout running here, once', () => {
    const msg = { id: 'c1', type: 'set', sid: 'w1', e: 0, x: '0025', i: 1, r: 4, done: true, at: 9 }
    expect(handle(msg)).toBe(true)
    expect(h.S.active.entries[0].sets[1]).toMatchObject({ r: 4, done: true, at: 9 })
    h.S.active.entries[0].sets[1].r = 6   // changed on the phone since
    expect(handle(msg)).toBe(true)
    expect(h.S.active.entries[0].sets[1].r).toBe(6)
  })

  it('is dropped for a workout that is no longer running', () => {
    expect(handle({ id: 'c2', type: 'set', sid: 'old', e: 0, i: 0, done: true })).toBe(true)
    expect(h.S.active.entries[0].sets[0].done).toBe(false)
  })
})

describe('the rest from the watch', () => {
  it('drives the rest timer of the workout running here', () => {
    handle({ id: 'r1', type: 'rest', sid: 'w1', op: 'start', sec: 90, at: Date.now() })
    expect(h.ui.startRest).toHaveBeenCalledWith(90)
    handle({ id: 'r2', type: 'rest', sid: 'w1', op: 'add', sec: 15 })
    expect(h.ui.addRest).toHaveBeenCalledWith(15)
    handle({ id: 'r3', type: 'rest', sid: 'w1', op: 'skip' })
    expect(h.ui.stopRest).toHaveBeenCalled()
    handle({ id: 'r4', type: 'rest', sid: 'other', op: 'pause' })
    expect(h.ui.pauseRest).not.toHaveBeenCalled()
  })
})

describe('finishing', () => {
  it('finishes the workout running here when the watch says so', () => {
    handle({ id: 'f1', type: 'finish', sid: 'w1' })
    expect(h.finished).toEqual(['w1'])
  })
})

describe('a session the watch ran alone', () => {
  const session = over => ({ id: 's-msg', type: 'session', sid: 's1', start: 1000, end: 5000, name: 'Legs', rids: ['r1'], raw: JSON.stringify([{ id: '0025', sets: [row()] }]), patches: [{ e: 0, x: '0025', i: 0, done: true, at: 2000 }], ...over })

  it('is saved through the finish path', () => {
    h.S.active = null
    expect(handle(session())).toBe(true)
    expect(h.committed).toHaveLength(1)
    expect(h.committed[0]).toMatchObject({ id: 's1', name: 'Legs', end: 5000, fromWatch: true })
  })

  it('waits in the inbox while a workout runs here', () => {
    h.commitOk = false
    expect(handle(session())).toBe(false)
    h.commitOk = true
    expect(handle(session())).toBe(true)
    expect(h.committed).toHaveLength(2)
  })

  it('is not saved twice', () => {
    h.S.active = null
    h.S.workouts = [{ id: 's1' }]
    expect(handle(session())).toBe(true)
    expect(h.committed).toEqual([])
  })
})

it('drops what it cannot read', () => {
  expect(handle(null)).toBe(true)
  expect(handle({ type: 42 })).toBe(true)
})
