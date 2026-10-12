import { describe, it, expect } from 'vitest'
import { projectName, exact } from './types'
describe('跨平台项目名称',()=>{
  it('识别 Windows 分隔符和尾部反斜杠',()=>{expect(projectName('C:\\Users\\dev\\project\\')).toBe('project')})
  it('识别 POSIX 路径及未知归属',()=>{expect(projectName('/workspace/project')).toBe('project');expect(projectName('未归属路径')).toBe('未归属路径')})
  it('小票保留完整数字',()=>{expect(exact(123456789)).toBe('123,456,789')})
})
