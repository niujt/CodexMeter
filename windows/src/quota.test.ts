import {expect,it,vi} from 'vitest'
import {createSSRApp, computed} from 'vue'
import {renderToString} from '@vue/server-renderer'
import {remainingQuota, quotaDisplay, quotaSampleLifetime, nextDisplayDeadline, defaultPreferences, type Snapshot} from './types'
const fixture = vi.hoisted(() => ({state: {} as Record<string, unknown>}))
vi.mock('./desktop', () => ({useDesktop: () => ({state:fixture.state,dark:computed(()=>false),icon:computed(()=>'/icons/flat-light.png'),refresh:vi.fn(),choose:vi.fn(),command:vi.fn()})}))
import Dashboard from './components/Dashboard.vue'
import FloatingBall from './components/FloatingBall.vue'
it('expires quota at reset and rejects invalid data',()=>{
 const rate={usedPercent:42,windowMinutes:10080,resetsAt:'2030-01-01T00:00:00Z'}
 expect(remainingQuota(rate,0)).toBe(58)
 expect(remainingQuota(rate,Date.parse(rate.resetsAt))).toBeNull()
 expect(remainingQuota({...rate,usedPercent:NaN},0)).toBeNull()
 expect(remainingQuota(null,0)).toBeNull()
 expect(remainingQuota({...rate,usedPercent:120},0)).toBe(0)
})
it('renders source sampling time and removes the current percentage for stale dashboard and floating quotas', async () => {
 const now = Date.parse('2026-10-13T10:00:00Z')
 const at = new Date(now).toISOString()
 const zero = {input:0,cachedInput:0,output:0,reasoningOutput:0,total:0}
 const snapshot = {allTime:zero,today:zero,lastSevenDays:zero,thisMonth:zero,dailyUsage:[],hourlyUsage:[],projects:[],todayProjects:[],monthProjects:[],models:[],records:[],sevenDayRate:{usedPercent:3,windowMinutes:10080,resetsAt:'2026-10-20T10:00:00Z'},primaryRate:null,sparkRate:null,replySpeedSamples:[],rateTimeline:[],quotaSamples:[],prediction:{percentPerHour:null,windowsUsed:[],remainingHours:null,willExhaust:false,health:'样本不足'},currentContextUsed:0,contextWindow:0,lastUpdated:at,observedAt:at,mainRateSampledAt:at,fileCount:1,sessionCount:1,dataPath:'synthetic',warnings:[],accountStatus:'synthetic',quotaWaitingMessage:'等待新采样',contextId:'synthetic',readStats:{parsedFiles:1,reusedFiles:0,incrementalFiles:0,bytesRead:0,persistedSummaries:0,aggregateBuilds:1}} satisfies Snapshot
 fixture.state = {snapshot,now,preferences:{...defaultPreferences},permissions:[],error:'',busy:false,status:'',lowPower:false}
 const fresh = await renderToString(createSSRApp(Dashboard))
 expect(fresh).toContain('<strong>97%</strong>')
 expect(fresh).toContain('采样于')
 expect(fresh).toContain('非实时')
 fixture.state.now = now + quotaSampleLifetime
 const old = await renderToString(createSSRApp(Dashboard))
 expect(old).not.toContain('<strong>97%</strong>')
 expect(old).toContain('旧采样')
 expect(old).toContain('上次剩余 97%')
 const ball = await renderToString(createSSRApp(FloatingBall))
 expect(ball).toContain('<strong>—</strong>')
 expect(ball).toContain('旧采样')
 expect(ball).toContain('采样于')
 fixture.state.preferences = {...defaultPreferences, floatingStyle:'summary'}
 const summary = await renderToString(createSSRApp(FloatingBall))
 expect(summary).toContain('上次剩余 97%')
 expect(summary).toContain('采样于')
})
it('uses the quota observation time rather than the latest file check', () => {
 const now = Date.parse('2026-10-13T10:00:00Z')
 const rate = {usedPercent:9,windowMinutes:10080,resetsAt:'2026-10-20T10:00:00Z'}
 const at = new Date(now).toISOString()
 expect(quotaDisplay(rate, at, now).remaining).toBe(91)
 expect(quotaDisplay(rate, at, now).label).toContain('非实时')
 const old = quotaDisplay(rate, at, now + quotaSampleLifetime)
 expect(old.remaining).toBeNull()
 expect(old.lastRemaining).toBe(91)
 expect(old.label).toContain('旧采样')
 expect(quotaDisplay(rate, null, now).remaining).toBeNull()
 expect(quotaDisplay(rate, 'invalid', now).remaining).toBeNull()
 expect(quotaDisplay(rate, new Date(now+1).toISOString(), now).remaining).toBeNull()
 const snapshot = {sevenDayRate:rate, primaryRate:null,sparkRate:null,mainRateSampledAt:at,observedAt:at,replySpeedSamples:[]} as unknown as Snapshot
 expect(nextDisplayDeadline(snapshot, now)).toBe(now + quotaSampleLifetime)
 expect(quotaDisplay(rate, at, Date.parse(rate.resetsAt)).lastRemaining).toBeNull()
})
