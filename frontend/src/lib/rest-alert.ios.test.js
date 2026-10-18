// The iPhone's rest-over alert: no RestAlert plugin there, so the end is a plain local
// notification at the same id. iOS hands it to a paired Apple Watch when the phone is locked.
import { beforeEach, describe, expect, it, vi } from 'vitest'

const h = vi.hoisted(() => {
  const store = new Map()
  vi.stubGlobal('localStorage', { getItem: k => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, String(v)), clear: () => store.clear() })
  return { local: [], registerPlugin: vi.fn() }
})

vi.mock('./mobile.js', () => ({ MOBILE: true, isAndroid: async () => false, isIOS: async () => true }))
vi.mock('@capacitor/core', () => ({ Capacitor: { getPlatform: () => 'ios' }, registerPlugin: (...a) => h.registerPlugin(...a) }))
const LocalNotifications = {
  checkPermissions: async () => ({ display: 'granted' }),
  requestPermissions: async () => ({ display: 'granted' }),
  schedule: async arg => { h.local.push(['schedule', arg]) },
  cancel: async arg => { h.local.push(['cancel', arg]) },
}
const load = async () => {
  const alert = await import('./rest-alert.js')
  alert._setIOSNotifications(LocalNotifications)
  return alert
}

const settle = async () => { for (let i = 0; i < 10; i++) await new Promise(r => setTimeout(r, 0)) }

beforeEach(() => {
  vi.resetModules()
  h.local = []
  h.registerPlugin.mockClear()
  localStorage.clear()
})

describe('the rest alert in the iOS app', () => {
  it('books the end as a local notification, and the caller needs no server push', async () => {
    const alert = await load()
    const at = Date.now() + 90_000
    await expect(alert.armRestAlert(at, { totalSec: 90 })).resolves.toBe(true)
    const booked = h.local.filter(([k]) => k === 'schedule').map(([, a]) => a.notifications[0])
    expect(booked).toHaveLength(1)
    expect(booked[0]).toMatchObject({ id: alert.REST_ALERT_ID, title: 'Rest’s over. Next set!' })
    expect(booked[0].schedule.at.getTime()).toBe(at)
    expect(h.registerPlugin).not.toHaveBeenCalled()
  })

  it('calls the booked end off on pause and on disarm', async () => {
    const alert = await load()
    await alert.armRestAlert(Date.now() + 90_000, { totalSec: 90 })
    h.local = []
    alert.holdRestAlert(60, 90)
    alert.disarmRestAlert()
    await settle()
    expect(h.local).toEqual([
      ['cancel', { notifications: [{ id: alert.REST_ALERT_ID }] }],
      ['cancel', { notifications: [{ id: alert.REST_ALERT_ID }] }],
    ])
  })

  it('books nothing for an end already past', async () => {
    const alert = await load()
    await expect(alert.armRestAlert(Date.now() - 1000, { totalSec: 90 })).resolves.toBe(false)
    await settle()
    expect(h.local.filter(([k]) => k === 'schedule')).toEqual([])
  })
})
