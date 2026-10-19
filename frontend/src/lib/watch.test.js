import { describe, it, expect } from 'vitest'
import { watchSessionView, buildWatchPack, buildLiveSnapshot, applySetPatch, prepareWatchSession, rememberCommand, restAction, WATCH_SEEN_MAX, WATCH_PACK_MAX } from './watch.js'
import { buildCombinedEntries } from './session-merge.js'
import { buildCompletedWorkout } from './finish-workout.js'
import { makeSideSet } from './workout-model.js'

const TODAY = '2026-10-19'   // a Monday
const st = (over = {}) => ({
  unit: 'kg', restSec: 90, workouts: [], exWeights: {}, dayPlan: {}, week: { 1: ['r1'] }, queue: null,
  routines: [
    { id: 'r1', name: 'Strength', prog: 'off', ex: [{ id: '0025', sets: 3, reps: 5, weight: 60 }, { id: '0031', sets: 2, reps: 8, weight: 40, restSec: 120 }] },
    { id: 'r2', name: 'Core', prog: 'off', ex: [{ id: '0047', sets: 2, reps: 12, weight: 0 }] },
    { id: 'empty', name: 'Nothing yet', ex: [] },
  ],
  ...over,
})

describe('watchSessionView', () => {
  it('walks each exercise set by set, resting its own rest after each and nothing after the last', () => {
    const S = st()
    const { entries } = buildCombinedEntries(S, ['r1'])
    const v = watchSessionView(S, entries)
    expect(v.order).toEqual([
      { e: 0, i: 0, rest: 90 }, { e: 0, i: 1, rest: 90 }, { e: 0, i: 2, rest: 90 },
      { e: 1, i: 0, rest: 120 }, { e: 1, i: 1, rest: 0 },
    ])
    expect(v.entries[0]).toMatchObject({ idx: 0, id: '0025', mode: 'reps', sets: [{ w: 60, r: 5, done: false }, {}, {}] })
    expect(v.entries[0].name).toBeTruthy()
    expect(v.entries[0].step).toBeGreaterThan(0)
  })

  it('goes round a superset member by member, resting only at the end of each round', () => {
    const S = st({ routines: [{ id: 'ss', name: 'SS', prog: 'off', ex: [
      { id: '0025', sets: 2, reps: 5, weight: 60, sg: 'a' }, { id: '0031', sets: 3, reps: 8, weight: 40, sg: 'a' },
    ] }] })
    const { entries } = buildCombinedEntries(S, ['ss'])
    const { order } = watchSessionView(S, entries)
    expect(order.map(s => [s.e, s.i, s.rest > 0])).toEqual([
      [0, 0, false], [1, 0, true], [0, 1, false], [1, 1, true], [1, 2, false],
    ])
  })

  it('shows a per-side row with both its sides', () => {
    const v = watchSessionView(st(), [{ id: '0025', target: { id: '0025' }, sets: [makeSideSet({ w: 20, r: 10 })] }])
    expect(v.entries[0].sets[0]).toMatchObject({ sides: { L: { w: 20, r: 5, done: false }, R: { w: 20, r: 5, done: false } } })
  })
})

describe('buildWatchPack', () => {
  it('puts today first and then every routine with exercises, each with the entries the phone would start', () => {
    const S = st()
    const pack = buildWatchPack(S, { now: 1, today: TODAY })
    expect(pack).toMatchObject({ v: 1, kind: 'pack', built: 1, unit: 'kg' })
    expect(pack.sessions.map(s => [s.key, !!s.today])).toEqual([['today', true], ['r2', false]])
    expect(pack.sessions[0]).toMatchObject({ rids: ['r1'], name: 'Strength' })
    expect(JSON.parse(pack.sessions[0].raw)).toEqual(buildCombinedEntries(S, ['r1']).entries)
    expect(pack.labels.done).toBe('Done')
  })

  it('lists every routine when nothing is planned today', () => {
    const pack = buildWatchPack(st({ week: {} }), { today: TODAY })
    expect(pack.sessions.map(s => s.key)).toEqual(['r1', 'r2'])
  })

  it('stops at the cap', () => {
    const routines = Array.from({ length: WATCH_PACK_MAX + 5 }, (_, k) => ({ id: 'r' + k, name: 'R' + k, prog: 'off', ex: [{ id: '0025', sets: 1, reps: 5, weight: 60 }] }))
    expect(buildWatchPack(st({ routines, week: {} }), { today: TODAY }).sessions).toHaveLength(WATCH_PACK_MAX)
  })
})

describe('buildLiveSnapshot', () => {
  const active = () => ({ id: 'w1', name: 'Strength', start: 1000, cur: 1, entries: buildCombinedEntries(st(), ['r1']).entries })

  it('is empty without a workout, and for an edit of a saved one or a past one', () => {
    expect(buildLiveSnapshot(st(), null).active).toBeNull()
    expect(buildLiveSnapshot(st({ active: { ...active(), editingWorkoutId: 'x' } }), null).active).toBeNull()
    expect(buildLiveSnapshot(st({ active: { ...active(), backfill: {} } }), null).active).toBeNull()
  })

  it('carries the workout, the rest counting down and the commands already applied', () => {
    const snap = buildLiveSnapshot(st({ active: active() }), { endsAt: 5000, total: 90, left: 40 }, { seen: ['c1'], now: 7 })
    expect(snap).toMatchObject({ kind: 'live', at: 7, seen: ['c1'], active: { sid: 'w1', cur: 1, rest: { endsAt: 5000, total: 90 } } })
    expect(snap.active.order).toHaveLength(5)
    expect(buildLiveSnapshot(st({ active: active() }), { endsAt: 5000, total: 90, left: 40, paused: true }).active.rest).toMatchObject({ paused: true, left: 40 })
    expect(buildLiveSnapshot(st({ active: active() }), { ready: true }).active.rest).toBeNull()
  })
})

describe('applySetPatch', () => {
  const entries = () => buildCombinedEntries(st(), ['r1']).entries

  it('writes the values and the tick, and stamps when the set was done', () => {
    const out = applySetPatch(entries(), { e: 0, x: '0025', i: 1, w: 62.5, r: 4, done: true, at: 1234 })
    expect(out[0].sets[1]).toMatchObject({ w: 62.5, r: 4, done: true, at: 1234 })
    expect(out[0].sets[0].done).toBe(false)
  })

  it('leaves what it was given alone', () => {
    const before = entries()
    const copy = JSON.parse(JSON.stringify(before))
    applySetPatch(before, { e: 0, i: 0, done: true })
    expect(before).toEqual(copy)
  })

  it('unticks without touching the values', () => {
    const done = applySetPatch(entries(), { e: 0, i: 0, done: true, at: 5 })
    const out = applySetPatch(done, { e: 0, i: 0, done: false })
    expect(out[0].sets[0]).toMatchObject({ w: 60, r: 5, done: false })
  })

  it('follows the exercise when the phone list moved, and drops a patch for one that is gone', () => {
    const list = entries()
    const moved = [list[1], list[0]]
    expect(applySetPatch(moved, { e: 0, x: '0025', i: 0, done: true })[1].sets[0].done).toBe(true)
    expect(applySetPatch(list, { e: 0, x: '9999', i: 0, done: true })).toBeNull()
  })

  it('makes up no row and takes no nonsense', () => {
    expect(applySetPatch(entries(), { e: 0, i: 9, done: true })).toBeNull()
    expect(applySetPatch(entries(), null)).toBeNull()
    const out = applySetPatch(entries(), { e: 0, i: 0, w: -5, r: 'many', done: 'yes' })
    expect(out[0].sets[0]).toMatchObject({ w: 60, r: 5, done: false })
  })

  it('ticks both sides of a per-side row, or one side when told which', () => {
    const list = [{ id: '0025', sets: [makeSideSet({ w: 20, r: 10 })] }]
    const both = applySetPatch(list, { e: 0, i: 0, done: true, at: 9 })
    expect(both[0].sets[0]).toMatchObject({ done: true, sides: { L: { done: true }, R: { done: true } } })
    const left = applySetPatch(list, { e: 0, i: 0, side: 'L', r: 6, done: true })
    expect(left[0].sets[0]).toMatchObject({ done: false, sides: { L: { r: 6, done: true }, R: { r: 5, done: false } } })
    const perSide = applySetPatch(list, { e: 0, i: 0, sides: { L: { r: 6 }, R: { r: 4 } }, done: true })
    expect(perSide[0].sets[0]).toMatchObject({ r: 10, done: true, sides: { L: { r: 6 }, R: { r: 4 } } })
  })
})

describe('prepareWatchSession', () => {
  const raw = () => JSON.stringify(buildCombinedEntries(st(), ['r1']).entries)

  it('rebuilds the session from what it was started with plus the watch’s changes, ready to finish', () => {
    const A = prepareWatchSession({ sid: 's1', start: new Date(2026, 9, 19, 18, 0).getTime(), name: 'Strength', rids: ['r1'], raw: raw(), patches: [
      { e: 0, x: '0025', i: 0, done: true, at: new Date(2026, 9, 19, 18, 5).getTime() },
      { e: 0, x: '0025', i: 1, r: 4, done: true, at: new Date(2026, 9, 19, 18, 8).getTime() },
    ] })
    expect(A).toMatchObject({ id: 's1', d: '2026-10-19', name: 'Strength', routineIds: ['r1'], fromWatch: true })
    expect(A.entries[0].sets.map(s => s.done)).toEqual([true, true, false])
    const w = buildCompletedWorkout(A, { end: new Date(2026, 9, 19, 18, 10).getTime() })
    expect(w.entries[0].sets.filter(s => s.done)).toHaveLength(2)
    expect(w.entries[0].sets[1].r).toBe(4)
  })

  it('saves nothing when no set was done or the entries are unreadable', () => {
    expect(prepareWatchSession({ raw: raw(), patches: [] })).toBeNull()
    expect(prepareWatchSession({ raw: '{nope', patches: [{ e: 0, i: 0, done: true }] })).toBeNull()
    expect(prepareWatchSession({ raw: '[{"id":"x"}]', patches: [] })).toBeNull()
    expect(prepareWatchSession(null)).toBeNull()
  })
})

describe('rememberCommand', () => {
  it('counts each command once and keeps only the newest', () => {
    const a = rememberCommand([], 'c1')
    expect(a).toEqual(['c1'])
    expect(rememberCommand(a, 'c1')).toBeNull()
    let list = []
    for (let k = 0; k < WATCH_SEEN_MAX + 10; k++) list = rememberCommand(list, 'c' + k)
    expect(list).toHaveLength(WATCH_SEEN_MAX)
    expect(list.at(-1)).toBe('c' + (WATCH_SEEN_MAX + 9))
  })
})

describe('restAction', () => {
  it('starts what is left of a rest the watch started a moment ago', () => {
    expect(restAction({ op: 'start', sec: 90, at: 10_000 }, 14_000)).toEqual({ op: 'start', sec: 86 })
    expect(restAction({ op: 'start', sec: 90, at: 0 }, 100_000)).toBeNull()
    expect(restAction({ op: 'add', sec: 15 })).toEqual({ op: 'add', sec: 15 })
    expect(restAction({ op: 'skip' })).toEqual({ op: 'skip' })
    expect(restAction({ op: 'boom' })).toBeNull()
  })
})
