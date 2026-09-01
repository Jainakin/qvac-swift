#!/usr/bin/env node

import { execFileSync } from 'node:child_process'
import { resolve } from 'node:path'

const repository = process.argv[2]
if (!repository || process.argv.length !== 3) {
  console.error('usage: require-clean-worktree.mjs <repository>')
  process.exit(2)
}

let worktreeStatus
try {
  worktreeStatus = execFileSync(
    'git',
    ['-C', resolve(repository), 'status', '--porcelain=v1', '--untracked-files=all'],
    { encoding: 'utf8' },
  )
} catch (error) {
  console.error(`[prepare-release] error: cannot inspect release working tree: ${error.message}`)
  process.exit(3)
}

if (worktreeStatus.length > 0) {
  console.error('[prepare-release] error: the release working tree must be completely clean, including untracked files')
  process.stderr.write(worktreeStatus)
  process.exit(3)
}
