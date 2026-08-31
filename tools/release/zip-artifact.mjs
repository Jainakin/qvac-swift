import { lstatSync, readdirSync, utimesSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { join } from 'node:path'

const fixedTime = new Date('2000-01-01T00:00:00.000Z')
const deterministicEnvironment = {
  ...process.env,
  TZ: 'UTC',
  LC_ALL: 'C',
  LANG: 'C',
}

function entries(root, relative = '') {
  const current = join(root, relative)
  const metadata = lstatSync(current)
  if (metadata.isSymbolicLink()) {
    throw new Error(`[zip-artifact] symbolic links are forbidden in release artifacts: ${relative || '<root>'}`)
  }
  const result = [relative]
  if (metadata.isDirectory()) {
    for (const child of readdirSync(current).sort()) {
      result.push(...entries(root, join(relative, child)))
    }
  }
  return result
}

export function packageDeterministicXCFramework({ frameworksDir, target, asset }) {
  if (!/^[A-Za-z0-9._@-]+$/.test(target)) throw new Error(`[zip-artifact] unsafe target: ${target}`)
  const rootName = `${target}.xcframework`
  const paths = entries(frameworksDir, rootName).filter(Boolean).sort()
  for (const relative of [...paths].reverse()) {
    utimesSync(join(frameworksDir, relative), fixedTime, fixedTime)
  }
  const zip = spawnSync('zip', ['-X', '-q', asset, '-@'], {
    cwd: frameworksDir,
    input: paths.join('\n') + '\n',
    encoding: 'utf8',
    env: deterministicEnvironment,
  })
  if (zip.status !== 0) throw new Error(`[zip-artifact] zip failed for ${target}: ${zip.stderr}`)

  const listing = spawnSync('unzip', ['-Z1', asset], {
    encoding: 'utf8',
    env: deterministicEnvironment,
  })
  if (listing.status !== 0) throw new Error(`[zip-artifact] cannot inspect ${asset}: ${listing.stderr}`)
  const archivedPaths = listing.stdout.split('\n').filter(Boolean)
  const unsafe = archivedPaths.find(path => {
    const components = path.split('/')
    return path.startsWith('/') || path.includes('\\')
      || components.includes('..') || components.includes('.')
      || !path.startsWith(`${rootName}/`)
  })
  if (archivedPaths.length === 0 || unsafe) {
    throw new Error(`[zip-artifact] archive escaped ${rootName}: ${unsafe ?? '<empty>'}`)
  }
}
