import {expect,it} from 'vitest'
import {remainingQuota} from './types'
it('expires quota at reset and rejects invalid data',()=>{
 const rate={usedPercent:42,windowMinutes:10080,resetsAt:'2030-01-01T00:00:00Z'}
 expect(remainingQuota(rate,0)).toBe(58)
 expect(remainingQuota(rate,Date.parse(rate.resetsAt))).toBeNull()
 expect(remainingQuota({...rate,usedPercent:NaN},0)).toBeNull()
 expect(remainingQuota(null,0)).toBeNull()
 expect(remainingQuota({...rate,usedPercent:120},0)).toBe(0)
})
