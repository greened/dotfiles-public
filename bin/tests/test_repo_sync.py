"""Tests for repo-sync.

Each case builds scratch repos in a temp dir: a bare origin, and a vm clone
and a mac clone at different paths under different roots. The mac is played
by LocalTransport, which runs the real `mac-agent` against the mac clone, or
by FakeEmacs, which records evals. Nothing here reaches a real Emacs socket.

Git is hermetic: no global or system config, so the global hook chain does
not run. $HOME is never redirected.
"""

import base64
import gzip
import importlib.machinery
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

SCRIPT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                      'repo-sync')

_loader = importlib.machinery.SourceFileLoader('repo_sync', SCRIPT)
_spec = importlib.util.spec_from_loader('repo_sync', _loader)
rs = importlib.util.module_from_spec(_spec)
_loader.exec_module(rs)

GIT_ENV = {
    'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1',
    'GIT_AUTHOR_NAME': 'Test', 'GIT_AUTHOR_EMAIL': 'test@example.com',
    'GIT_COMMITTER_NAME': 'Test', 'GIT_COMMITTER_EMAIL': 'test@example.com',
    'GIT_TERMINAL_PROMPT': '0',
}
_saved = {}


def setUpModule():
  for k, v in GIT_ENV.items():
    _saved[k] = os.environ.get(k)
    os.environ[k] = v


def tearDownModule():
  for k, v in _saved.items():
    if v is None:
      os.environ.pop(k, None)
    else:
      os.environ[k] = v


def git(*args, cwd=None):
  r = subprocess.run(['git'] + list(args), cwd=cwd, capture_output=True,
                     text=True, timeout=60)
  if r.returncode != 0:
    raise AssertionError('git %s failed: %s' % (' '.join(args), r.stderr))
  return r.stdout.strip()


class LocalTransport:
  """The mac, as a `mac-agent` subprocess on this machine."""

  def __init__(self, tmp):
    self.tmp = tmp
    self.calls = []

  def run_job(self, kind, job):
    self.calls.append(kind)
    d = tempfile.mkdtemp(dir=self.tmp, prefix='job-')
    path = os.path.join(d, 'job.json')
    with open(path, 'w') as f:
      json.dump(job, f)
    subprocess.run([sys.executable, SCRIPT, 'mac-agent', kind, path],
                   capture_output=True, timeout=120)
    with open(os.path.join(d, 'result.json.gz'), 'rb') as f:
      return rs.decode_result(f.read())


class World:
  """A bare origin plus a vm clone and a mac clone of it."""

  def __init__(self, tc):
    self.tc = tc
    self.n = 0
    self.tmp = os.path.realpath(tempfile.mkdtemp(prefix='repo-sync-test-'))
    tc.addCleanup(shutil.rmtree, self.tmp, True)
    self.origin = os.path.join(self.tmp, 'origin.git')
    git('init', '-q', '--bare', '-b', 'main', self.origin)
    self.seed = self.clone(os.path.join(self.tmp, 'seed'))
    self.commit(self.seed, 'initial')
    git('push', '-q', 'origin', 'main', cwd=self.seed)
    self.vmroot = os.path.join(self.tmp, 'vm')
    self.macroot = os.path.join(self.tmp, 'mac')
    self.vm = self.clone(os.path.join(self.vmroot, 'proj', 'repo'))
    self.mac = self.clone(os.path.join(self.macroot, 'work', 'repo'))
    self.state = os.path.join(self.tmp, 'state')
    os.makedirs(self.state, mode=0o700)
    self.files = {}
    for m in ('vm', 'mac'):
      order = os.path.join(self.tmp, m + '.order')
      with open(order, 'w') as f:
        f.write('# overlays\nbase\nwork\n')
      self.files[m] = {'order': order, 'includes': None}
    self.transport = None
    self.out = None

  def clone(self, dest):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    git('clone', '-q', self.origin, dest)
    return dest

  def commit(self, clone, msg):
    self.n += 1
    with open(os.path.join(clone, 'f%d.txt' % self.n), 'w') as f:
      f.write(msg + '\n')
    git('add', '-A', cwd=clone)
    git('commit', '-q', '-m', msg, cwd=clone)
    return self.tip(clone)

  def tip(self, clone, ref='HEAD'):
    return git('rev-parse', ref, cwd=clone)

  def origin_tip(self, branch='main'):
    return git('rev-parse', 'refs/heads/' + branch, cwd=self.origin)

  def gate(self, body):
    path = os.path.join(self.tmp, 'gate-%d.sh' % len(os.listdir(self.tmp)))
    with open(path, 'w') as f:
      f.write('#!/bin/sh\n' + body)
    os.chmod(path, 0o700)
    return path

  def allow(self):
    return 'gate %s\n' % self.gate('cat > /dev/null\n')

  def config_text(self, extra=''):
    return ('mac-socket /nonexistent/emacs-server\n'
            'root %s %s\n'
            'repo %s\n' % (self.vmroot, self.macroot, self.origin)) + extra

  def cfg(self, extra=''):
    path = os.path.join(self.tmp, 'repos.list')
    with open(path, 'w') as f:
      f.write(self.config_text(extra))
    return rs.parse_config([path])

  def driver(self, extra='', overrides=None):
    self.transport = LocalTransport(self.tmp)
    self.out = io.StringIO()
    return rs.Driver(self.cfg(extra), self.transport, self.state, self.files,
                     out=self.out, job_overrides=overrides)

  def report(self, extra=''):
    d = self.driver(extra)
    code = d.report(as_json=True)
    body = json.loads(self.out.getvalue())
    return code, body['rows']

  def apply(self, extra='', push=()):
    d = self.driver(extra)
    code = d.apply(list(push), as_json=True)
    return code, json.loads(self.out.getvalue())['rows']


def kinds(rows, kind, branch=None):
  return [r for r in rows if r['kind'] == kind
          and (branch is None or r.get('branch') == branch)]


class Decide(unittest.TestCase):

  def setUp(self):
    self.w = World(self)

  def test_01_in_sync_gives_no_action(self):
    code, rows = self.w.report()
    self.assertEqual(code, 0)
    self.assertEqual(len(kinds(rows, 'SYNC', 'main')), 1)
    self.assertFalse([r for r in rows if r['kind'] in rs.ACTIONABLE])

  def test_02_mac_behind_origin_is_auto_and_apply_fast_forwards(self):
    new = self.w.commit(self.w.vm, 'vm work')
    git('push', '-q', 'origin', 'main', cwd=self.w.vm)
    code, rows = self.w.report()
    self.assertEqual(code, 0)
    auto = kinds(rows, 'AUTO', 'main')
    self.assertEqual([(r['machine'], r['to']) for r in auto], [('mac', new)])
    code, _ = self.w.apply()
    self.assertEqual(code, 0)
    self.assertEqual(self.w.tip(self.w.mac), new)

  def test_03_both_behind_by_different_amounts_both_fast_forward(self):
    self.w.commit(self.w.seed, 'one')
    git('push', '-q', 'origin', 'main', cwd=self.w.seed)
    git('pull', '-q', '--ff-only', cwd=self.w.vm)
    self.w.commit(self.w.seed, 'two')
    new = self.w.commit(self.w.seed, 'three')
    git('push', '-q', 'origin', 'main', cwd=self.w.seed)
    _, rows = self.w.report()
    auto = {r['machine']: r for r in kinds(rows, 'AUTO', 'main')}
    self.assertEqual(auto['vm']['count'], 2)
    self.assertEqual(auto['mac']['count'], 3)
    self.w.apply()
    self.assertEqual(self.w.tip(self.w.vm), new)
    self.assertEqual(self.w.tip(self.w.mac), new)

  def test_04_vm_ahead_asks_and_pushes_only_when_named(self):
    before = self.w.origin_tip()
    new = self.w.commit(self.w.vm, 'unpushed')
    extra = self.w.allow()
    code, rows = self.w.report(extra)
    self.assertEqual(code, 1)
    ask = kinds(rows, 'ASK-PUSH', 'main')
    self.assertEqual(len(ask), 1)
    self.assertEqual((ask[0]['machine'], ask[0]['sha'], ask[0]['follow']),
                     ('vm', new, 'mac'))
    self.w.apply(extra)
    self.assertEqual(self.w.origin_tip(), before)
    self.assertNotEqual(self.w.tip(self.w.mac), new)
    code, out = self.w.apply(extra, push=[ask[0]['id']])
    self.assertEqual(code, 0, out)
    self.assertEqual(self.w.origin_tip(), new)
    self.assertEqual(self.w.tip(self.w.mac), new)

  def branch_on_both(self, name, push=True):
    git('checkout', '-q', '-b', name, cwd=self.w.vm)
    if push:
      git('push', '-q', '-u', 'origin', name, cwd=self.w.vm)
      git('fetch', '-q', 'origin', cwd=self.w.mac)
      git('checkout', '-q', '-b', name, 'origin/' + name, cwd=self.w.mac)
    else:
      git('checkout', '-q', '-b', name, cwd=self.w.mac)

  def test_05_diverged_branch_reports_extras_remote_and_wip(self):
    self.branch_on_both('feat')
    self.w.commit(self.w.vm, 'wip: transfer')
    self.w.commit(self.w.mac, 'finished the work')
    code, rows = self.w.report()
    self.assertEqual(code, 1)
    d = kinds(rows, 'DIVERGED', 'feat')[0]
    self.assertTrue(d['remote'])
    self.assertFalse(d['beyond'])
    sides = {s['side']: s for s in d['sides']}
    self.assertEqual([e[2] for e in sides['vm']['extras']], ['wip: transfer'])
    self.assertTrue(sides['vm']['wip'])
    self.assertEqual([e[2] for e in sides['mac']['extras']],
                     ['finished the work'])
    self.assertFalse(sides['mac']['wip'])
    self.assertEqual(sides['origin']['extras'], [])
    text = rs.render(rows, 'h', False)
    self.assertIn('[all wip]', text)
    self.assertIn('remote: yes', text)

  def test_05b_diverged_branch_on_no_remote(self):
    self.branch_on_both('loc', push=False)
    self.w.commit(self.w.vm, 'vm side')
    self.w.commit(self.w.mac, 'mac side')
    _, rows = self.w.report()
    d = kinds(rows, 'DIVERGED', 'loc')[0]
    self.assertFalse(d['remote'])
    self.assertEqual(sorted(s['side'] for s in d['sides']), ['mac', 'vm'])

  def test_06_leave_list_gives_left_and_no_question(self):
    self.branch_on_both('feat')
    self.w.commit(self.w.vm, 'wip: a')
    self.w.commit(self.w.mac, 'b')
    code, rows = self.w.report('leave %s feat\n' % self.w.origin)
    self.assertEqual(len(kinds(rows, 'LEFT', 'feat')), 1)
    self.assertFalse(kinds(rows, 'DIVERGED'))
    self.assertEqual(code, 0)

  def test_07_one_machine_branch_is_never_created(self):
    git('branch', 'solo', cwd=self.w.vm)
    git('push', '-q', 'origin', 'solo', cwd=self.w.vm)
    git('branch', 'maconly', cwd=self.w.mac)
    _, rows = self.w.report()
    only = {r['branch']: r['machine'] for r in kinds(rows, 'ONLY')}
    self.assertEqual(only, {'solo': 'vm', 'maconly': 'mac'})
    self.w.apply()
    heads = lambda c: git('for-each-ref', '--format=%(refname:short)',
                          'refs/heads', cwd=c).split()
    self.assertNotIn('solo', heads(self.w.mac))
    self.assertNotIn('maconly', heads(self.w.vm))
    self.assertNotIn('maconly', heads(self.w.origin))

  def test_08_tracked_dirt_asks_and_leaves_the_ref(self):
    self.w.commit(self.w.vm, 'vm work')
    git('push', '-q', 'origin', 'main', cwd=self.w.vm)
    before = self.w.tip(self.w.mac)
    with open(os.path.join(self.w.mac, 'f1.txt'), 'a') as f:
      f.write('edit\n')
    code, rows = self.w.report()
    self.assertEqual(code, 1)
    dirty = kinds(rows, 'ASK-DIRTY', 'main')
    self.assertEqual([(r['machine'], r['files']) for r in dirty],
                     [('mac', ['M f1.txt'])])
    self.assertFalse(kinds(rows, 'AUTO'))
    self.w.apply()
    self.assertEqual(self.w.tip(self.w.mac), before)

  def test_09_untracked_only_still_fast_forwards_with_a_note(self):
    new = self.w.commit(self.w.vm, 'vm work')
    git('push', '-q', 'origin', 'main', cwd=self.w.vm)
    with open(os.path.join(self.w.mac, 'scratch.out'), 'w') as f:
      f.write('x\n')
    code, rows = self.w.report()
    self.assertEqual(code, 0)
    self.assertEqual(len(kinds(rows, 'AUTO', 'main')), 1)
    note = kinds(rows, 'NOTE', 'main')
    self.assertEqual(note[0]['files'], ['scratch.out'])
    self.w.apply()
    self.assertEqual(self.w.tip(self.w.mac), new)

  def test_10_feature_branch_with_no_remote_asks_and_pushes_nothing(self):
    self.branch_on_both('loc', push=False)
    self.w.commit(self.w.vm, 'vm only')
    code, rows = self.w.report()
    self.assertEqual(code, 1)
    ask = kinds(rows, 'ASK', 'loc')
    self.assertEqual([(r['machine'], r['count']) for r in ask], [('vm', 1)])
    self.assertFalse(kinds(rows, 'ASK-PUSH'))
    d = self.w.driver()
    with self.assertRaises(rs.Error):
      d.apply(['repo:loc:vm'])
    self.assertNotIn('loc', git('branch', '--list', cwd=self.w.origin))

  def test_11_unlisted_url_and_exclude_path_are_skipped(self):
    other = os.path.join(self.w.tmp, 'other.git')
    git('init', '-q', '--bare', '-b', 'main', other)
    git('clone', '-q', other, os.path.join(self.w.vmroot, 'proj', 'other'))
    self.w.clone(os.path.join(self.w.vmroot, 'scratch', 'repo2'))
    d = self.w.driver('exclude-path %s/scratch/*\n' % self.w.vmroot)
    vm, mac = d.collect()
    self.assertEqual(list(vm['repos']), [rs.normalize_url(self.w.origin)])
    self.assertEqual([c['top'] for c in vm['repos'][rs.normalize_url(self.w.origin)]],
                     [self.w.vm])
    rows = rs.decide(vm, mac, d.cfg)
    self.assertFalse(kinds(rows, 'DUPLICATE'))

  def test_11b_two_clones_of_one_url_is_a_duplicate(self):
    self.w.clone(os.path.join(self.w.vmroot, 'scratch', 'repo2'))
    code, rows = self.w.report()
    self.assertEqual(code, 1)
    self.assertEqual([r['machine'] for r in kinds(rows, 'DUPLICATE')], ['vm'])

  def test_12_url_forms_match_across_paths(self):
    forms = ['git@example.com:owner/repo.git', 'git@example.com:owner/repo',
             'https://example.com/owner/repo', 'https://example.com/owner/repo.git/',
             'ssh://git@example.com:22/owner/repo.git',
             'https://user@EXAMPLE.com/owner/repo']
    self.assertEqual({rs.normalize_url(f) for f in forms},
                     {'example.com/owner/repo'})
    self.assertEqual(rs.normalize_url('git@alias:owner/repo.git',
                                      {'alias': 'example.com'}),
                     'example.com/owner/repo')
    for clone, url in ((self.w.vm, 'git@alias:owner/repo.git'),
                       (self.w.mac, 'https://example.com/owner/repo')):
      git('remote', 'set-url', 'origin', url, cwd=clone)
      git('config', 'url.%s.insteadOf' % self.w.origin, url, cwd=clone)
    self.w.commit(self.w.seed, 'more')
    git('push', '-q', 'origin', 'main', cwd=self.w.seed)
    d = self.w.driver()
    d.cfg = rs.parse_config([self._list('mac-socket /x\nroot %s %s\n'
                                        'host-alias alias example.com\n'
                                        'repo ssh://git@example.com/owner/repo\n'
                                        % (self.w.vmroot, self.w.macroot))])
    vm, mac = d.collect()
    rows = rs.decide(vm, mac, d.cfg)
    self.assertEqual(sorted(r['machine'] for r in kinds(rows, 'AUTO', 'main')),
                     ['mac', 'vm'])

  def _list(self, text):
    path = os.path.join(self.w.tmp, 'alt.list')
    with open(path, 'w') as f:
      f.write(text)
    return path

  def test_13_a_branch_without_the_origin_upstream_is_a_question(self):
    git('branch', 'nou', cwd=self.w.vm)
    git('push', '-q', 'origin', 'nou', cwd=self.w.vm)
    git('fetch', '-q', 'origin', cwd=self.w.mac)
    git('branch', '-q', '--no-track', 'nou', 'origin/nou', cwd=self.w.mac)
    git('branch', '-q', '--no-track', 'other', 'origin/main', cwd=self.w.vm)
    git('fetch', '-q', 'origin', cwd=self.w.seed)
    git('checkout', '-q', '-b', 'nou', 'origin/nou', cwd=self.w.seed)
    self.w.commit(self.w.seed, 'more on nou')
    git('push', '-q', 'origin', 'nou', cwd=self.w.seed)
    git('branch', '-q', '-u', 'origin/main', 'nou', cwd=self.w.mac)
    vm = rs.take_inventory(self.w.driver().job('vm'))
    self.assertIsNone(vm['repos'][rs.normalize_url(self.w.origin)][0]
                      ['branches']['nou']['upstream'])
    self.assertNotIn('@{u}', json.dumps(vm))
    before = self.w.tip(self.w.mac, 'refs/heads/nou')
    code, rows = self.w.report()
    self.assertEqual(code, 1)
    ask = kinds(rows, 'ASK-UPSTREAM', 'nou')
    self.assertEqual([r['machine'] for r in ask], ['vm,mac'])
    self.assertIn('vm unset', ask[0]['text'])
    self.assertIn('mac refs/remotes/origin/main', ask[0]['text'])
    self.assertIn('no side holds unpushed commits', ask[0]['text'])
    self.assertFalse(kinds(rows, 'AUTO', 'nou'))
    git('branch', '-q', '-u', 'origin/nou', 'nou', cwd=self.w.vm)
    _, rows = self.w.report()
    ask = kinds(rows, 'ASK-UPSTREAM', 'nou')
    self.assertEqual([r['machine'] for r in ask], ['mac'])
    self.w.apply()
    self.assertEqual(self.w.tip(self.w.mac, 'refs/heads/nou'), before)

  def test_13b_unset_upstream_hides_no_unpushed_commits(self):
    git('checkout', '-q', '-b', 'feat', cwd=self.w.vm)
    git('push', '-q', 'origin', 'feat', cwd=self.w.vm)
    git('fetch', '-q', 'origin', cwd=self.w.mac)
    git('branch', '-q', '--track', 'feat', 'origin/feat', cwd=self.w.mac)
    self.w.commit(self.w.vm, 'unpushed on feat')
    before = self.w.origin_tip('feat')
    code, rows = self.w.report()
    self.assertEqual(code, 1)
    ask = kinds(rows, 'ASK-UPSTREAM', 'feat')
    self.assertEqual([r['machine'] for r in ask], ['vm'])
    self.assertIn('vm holds commits the other side or origin lacks',
                  ask[0]['text'])
    self.assertIn('ASK-UPSTREAM', rs.render(rows, 'h', False))
    self.w.apply()
    self.assertEqual(self.w.origin_tip('feat'), before)

  def test_14_hung_fetch_fails_with_the_clone_path(self):
    git('remote', 'set-url', 'origin', 'ssh://example.invalid/r.git',
        cwd=self.w.vm)
    job = {'machine': 'vm', 'roots': [self.w.vmroot],
           'repos': ['example.invalid/r'], 'ssh_base': 'sleep 60;:',
           'fetch_timeout': 1}
    start = time.monotonic()
    inv = rs.take_inventory(job)
    self.assertLess(time.monotonic() - start, 20)
    clone = inv['repos']['example.invalid/r'][0]
    self.assertEqual(clone['fetch'], 'fetch timed out after 1s')
    mac = dict(inv, repos={}, home=inv['home'])
    cfg = rs.parse_config([self._list('mac-socket /x\nrepo ssh://example.invalid/r\n')])
    rows = rs.decide(inv, mac, cfg)
    failed = kinds(rows, 'FAILED')
    self.assertEqual([(r['machine'], r['path']) for r in failed],
                     [('vm', rs.tilde(self.w.vm, inv['home']))])
    self.assertEqual(rs.exit_code(rows), 1)

  def test_15_order_and_email_drift_give_identity(self):
    with open(self.w.files['mac']['order'], 'w') as f:
      f.write('base\n')
    git('config', 'user.email', 'work@example.com', cwd=self.w.mac)
    code, rows = self.w.report()
    self.assertEqual(code, 1)
    texts = [r['text'] for r in kinds(rows, 'IDENTITY')]
    self.assertIn('mac .order lacks work', texts)
    self.assertTrue(any('user.email' in t and 'work@example.com' in t
                        for t in texts), texts)

  def test_15b_include_lists_compare_through_the_path_map(self):
    cfg = self.w.cfg()
    vm = {'order': None, 'includes': [self.w.vmroot + '/ov/a/git/config'],
          'roots': [self.w.vmroot], 'home': '/home/v', 'repos': {}}
    mac = {'order': None, 'includes': [self.w.macroot + '/ov/a/git/config'],
           'roots': [self.w.macroot], 'home': '/Users/m', 'repos': {}}
    self.assertEqual(rs.identity_rows(vm, mac, cfg), [])
    mac['includes'] = []
    self.assertEqual(len(rs.identity_rows(vm, mac, cfg)), 1)

  def test_16_tip_moved_after_the_report_refuses(self):
    self.w.commit(self.w.vm, 'vm work')
    git('push', '-q', 'origin', 'main', cwd=self.w.vm)
    before = self.w.tip(self.w.mac)
    self.w.report()
    self.w.commit(self.w.seed, 'late')
    git('pull', '-q', '--rebase', cwd=self.w.seed)
    git('push', '-q', 'origin', 'main', cwd=self.w.seed)
    code, out = self.w.apply()
    self.assertEqual(code, 1)
    self.assertEqual([r['text'] for r in kinds(out, 'REFUSED')],
                     ['changed since the report'])
    self.assertEqual(self.w.tip(self.w.mac), before)

  def test_17_refusing_gates_refuse_the_push(self):
    cases = {
        'deny': 'echo \'{"hookSpecificOutput": {"permissionDecision": '
                '"deny", "permissionDecisionReason": "no marker"}}\'\n',
        'ask': 'echo \'{"hookSpecificOutput": {"permissionDecision": '
               '"ask"}}\'\n',
        'block': 'echo \'{"decision": "block", "reason": "no"}\'\n',
        'exit 2': 'echo blocked >&2\nexit 2\n',
        'hso not an object': 'echo \'{"hookSpecificOutput": "deny"}\'\n',
        'not json': 'echo maybe\n',
        'json list': 'echo \'[]\'\n',
        'timeout': 'sleep 30\n',
    }
    for name, body in cases.items():
      with self.subTest(gate=name):
        self.w = World(self)
        new = self.w.commit(self.w.vm, 'unpushed')
        before = self.w.origin_tip()
        extra = 'gate %s\n' % self.w.gate('cat > /dev/null\n' + body)
        _, rows = self.w.report(extra)
        pid = kinds(rows, 'ASK-PUSH')[0]['id']
        with mock.patch.object(rs, 'GATE_TIMEOUT', 1):
          code, out = self.w.apply(extra, push=[pid])
        self.assertEqual(code, 1)
        self.assertEqual(len(kinds(out, 'REFUSED')), 1, out)
        self.assertEqual(self.w.origin_tip(), before)
        self.assertNotEqual(self.w.tip(self.w.mac), new)

  def test_17_no_gate_configured_refuses_every_push(self):
    self.w.commit(self.w.vm, 'unpushed')
    before = self.w.origin_tip()
    _, rows = self.w.report()
    code, out = self.w.apply(push=[kinds(rows, 'ASK-PUSH')[0]['id']])
    self.assertEqual(code, 1)
    self.assertIn('no gate', kinds(out, 'REFUSED')[0]['text'])
    self.assertEqual(self.w.origin_tip(), before)

  def test_17b_allowing_gate_sees_the_exact_push(self):
    new = self.w.commit(self.w.vm, 'unpushed')
    seen = os.path.join(self.w.tmp, 'seen.json')
    g = self.w.gate('cat > %s\n' % seen)
    extra = 'gate %s\n' % g
    _, rows = self.w.report(extra)
    code, _ = self.w.apply(extra, push=[kinds(rows, 'ASK-PUSH')[0]['id']])
    self.assertEqual(code, 0)
    with open(seen) as f:
      event = json.load(f)
    self.assertEqual(event['tool_name'], 'Bash')
    self.assertEqual(event['tool_input']['command'],
                     'cd %s && git push origin %s:refs/heads/main'
                     % (self.w.vm, new))
    self.assertEqual(self.w.origin_tip(), new)

  def test_18_apply_twice_is_a_no_op_the_second_time(self):
    new = self.w.commit(self.w.vm, 'vm work')
    git('push', '-q', 'origin', 'main', cwd=self.w.vm)
    self.w.report()
    self.w.apply()
    self.assertEqual(self.w.tip(self.w.mac), new)
    code, out = self.w.apply()
    self.assertEqual((code, out), (0, []))
    self.assertEqual(self.w.transport.calls, [])

  def test_21_detached_head_worktree_is_ignored(self):
    det = os.path.join(self.w.vmroot, 'proj', 'det')
    git('worktree', 'add', '-q', '--detach', det, cwd=self.w.vm)
    d = self.w.driver()
    vm = rs.take_inventory(d.job('vm'))
    clone = vm['repos'][rs.normalize_url(self.w.origin)]
    self.assertEqual(len(clone), 1)
    self.assertEqual([w['path'] for w in clone[0]['worktrees']], [self.w.vm])

  def test_after_hook_runs_where_the_clone_moved(self):
    new = self.w.commit(self.w.vm, 'vm work')
    git('push', '-q', 'origin', 'main', cwd=self.w.vm)
    mark = os.path.join(self.w.tmp, 'after-ran')
    extra = 'after %s mac /bin/sh -c pwd>%s\n' % (self.w.origin, mark)
    _, rows = self.w.report(extra)
    self.assertEqual([r['machine'] for r in kinds(rows, 'AFTER')], ['mac'])
    code, out = self.w.apply(extra)
    self.assertEqual(code, 0, out)
    self.assertEqual(self.w.tip(self.w.mac), new)
    with open(mark) as f:
      self.assertEqual(f.read().strip(), self.w.mac)


class MalformedApply(LocalTransport):
  """A mac whose apply and after jobs answer with something not a dict."""

  def run_job(self, kind, job):
    if kind in ('apply', 'after'):
      self.calls.append(kind)
      return ['not', 'a', 'dict']
    return LocalTransport.run_job(self, kind, job)


class Apply(unittest.TestCase):
  """The moves, and every check that must refuse one."""

  def setUp(self):
    self.w = World(self)

  def mac_job(self):
    return self.w.driver().job('mac')

  def side_branch(self, mac_checkout=False):
    """`side` on origin and both clones, then two more commits on origin."""
    git('checkout', '-q', '-b', 'side', cwd=self.w.vm)
    git('push', '-q', '-u', 'origin', 'side', cwd=self.w.vm)
    base = self.w.tip(self.w.vm)
    git('fetch', '-q', 'origin', cwd=self.w.mac)
    git('branch', '-q', '--track', 'side', 'origin/side', cwd=self.w.mac)
    if mac_checkout:
      git('checkout', '-q', 'side', cwd=self.w.mac)
    mid = self.w.commit(self.w.vm, 'mid')
    git('push', '-q', 'origin', 'side', cwd=self.w.vm)
    top = self.w.commit(self.w.vm, 'top')
    git('push', '-q', 'origin', 'side', cwd=self.w.vm)
    git('checkout', '-q', 'main', cwd=self.w.vm)
    return base, mid, top

  def mac_push_id(self):
    """Give the mac ASK-PUSH row of the saved plan an id, as no report does."""
    path = os.path.join(self.w.state, 'plan.json')
    with open(path) as f:
      plan = json.load(f)
    row = [r for r in plan['rows'] if r['kind'] == 'ASK-PUSH'][0]
    self.assertEqual((row['machine'], row['id']), ('mac', None))
    row['id'] = 'forced:mac'
    with open(path, 'w') as f:
      json.dump(plan, f)
    return row['id']

  def test_mac_ahead_is_a_question_with_no_push_id(self):
    self.w.commit(self.w.mac, 'mac only')
    code, rows = self.w.report(self.w.allow())
    self.assertEqual(code, 1)
    ask = kinds(rows, 'ASK-PUSH', 'main')
    self.assertEqual([(r['machine'], r['id']) for r in ask], [('mac', None)])
    text = rs.render(rows, 'h', False)
    self.assertIn('push it from the mac', text)
    self.assertNotIn('id=', text)
    with self.assertRaises(rs.Error):
      self.w.driver(self.w.allow()).apply(['origin:main:mac'])

  def test_branch_checked_out_after_the_inventory_is_not_moved(self):
    base, mid, _ = self.side_branch()
    job = self.mac_job()
    inv = rs.take_inventory(dict(job, want={}), do_fetch=False)
    wt = os.path.join(self.w.macroot, 'work', 'wt')
    git('worktree', 'add', '-q', wt, 'side', cwd=self.w.mac)
    res = rs.do_action({'aid': '0', 'op': 'ff', 'key': rs.normalize_url(
        self.w.origin), 'branch': 'side', 'from': base, 'to': mid}, inv, job)
    self.assertFalse(res['ok'], res)
    self.assertEqual(self.w.tip(self.w.mac, 'refs/heads/side'), base)
    self.assertEqual(git('status', '--porcelain', cwd=wt), '')

  def test_probe_reports_the_fetch_guard(self):
    v = rs.agent_version({})
    self.assertTrue(v['fetch_by_sha'])
    self.assertTrue(v['fetch_refuses_checked_out'])
    d = self.w.driver()
    self.assertEqual(d.probe(), 0)
    self.assertIn('fetch-into-branch guard ok', self.w.out.getvalue())

  def counting_gate(self):
    """A gate that allows, and counts its calls in a file."""
    count = os.path.join(self.w.tmp, 'gate-calls')
    open(count, 'w').close()
    return count, 'gate %s\n' % self.w.gate(
        'cat > /dev/null\necho call >> %s\n' % count)

  def calls(self, count):
    with open(count) as f:
      return len(f.read().split())

  def trust(self):
    return 'push-trust %s\n' % self.w.origin

  def test_forged_mac_id_for_an_untrusted_repo_is_refused(self):
    self.w.commit(self.w.mac, 'mac only')
    before = self.w.origin_tip()
    count, extra = self.counting_gate()
    self.w.report(extra)
    code, out = self.w.apply(extra, push=[self.mac_push_id()])
    self.assertEqual(code, 1)
    self.assertIn('no longer push-trust', kinds(out, 'REFUSED')[0]['text'])
    self.assertEqual(self.w.origin_tip(), before)
    self.assertEqual(self.calls(count), 0)

  def test_trusted_mac_push_skips_the_gate_and_the_vm_follows(self):
    new = self.w.commit(self.w.mac, 'mac work')
    count, extra = self.counting_gate()
    extra += self.trust() + 'after %s vm /bin/true\n' % self.w.origin
    code, rows = self.w.report(extra)
    self.assertEqual(code, 1)
    ask = kinds(rows, 'ASK-PUSH', 'main')[0]
    self.assertEqual((ask['machine'], ask['id'], ask['follow']),
                     ('mac', 'origin:main:mac', 'vm'))
    self.assertIn('trusted: your --push approval replaces the gate',
                  rs.render(rows, 'h', False))
    self.assertEqual([r['machine'] for r in kinds(rows, 'AFTER')], ['vm'])
    code, out = self.w.apply(extra, push=[ask['id']])
    self.assertEqual(code, 0, out)
    self.assertEqual(self.w.origin_tip(), new)
    self.assertEqual(self.w.tip(self.w.vm), new)
    self.assertEqual(self.calls(count), 0)

  def test_trust_removed_between_report_and_apply_refuses(self):
    self.w.commit(self.w.mac, 'mac work')
    before = self.w.origin_tip()
    count, extra = self.counting_gate()
    _, rows = self.w.report(extra + self.trust())
    code, out = self.w.apply(extra, push=[kinds(rows, 'ASK-PUSH')[0]['id']])
    self.assertEqual(code, 1)
    self.assertIn('no longer push-trust', kinds(out, 'REFUSED')[0]['text'])
    self.assertEqual(self.w.origin_tip(), before)

  def test_trusted_mac_push_refuses_when_the_tip_moved(self):
    self.w.commit(self.w.mac, 'mac work')
    before = self.w.origin_tip()
    extra = self.w.allow() + self.trust()
    _, rows = self.w.report(extra)
    self.w.commit(self.w.mac, 'more mac work')
    code, out = self.w.apply(extra, push=[kinds(rows, 'ASK-PUSH')[0]['id']])
    self.assertEqual(code, 1)
    self.assertIn('changed since the report', kinds(out, 'REFUSED')[0]['text'])
    self.assertEqual(self.w.origin_tip(), before)

  def test_trusted_mac_push_refuses_when_the_remote_branch_is_gone(self):
    w = self.w

    class DeleteFirst(LocalTransport):
      """Deletes the remote branch just before the mac apply job runs."""

      def run_job(self, kind, job):
        if kind == 'apply':
          git('push', '-q', 'origin', '--delete', 'feat', cwd=w.seed)
        return LocalTransport.run_job(self, kind, job)

    git('checkout', '-q', '-b', 'feat', cwd=w.mac)
    git('push', '-q', '-u', 'origin', 'feat', cwd=w.mac)
    git('fetch', '-q', 'origin', cwd=w.vm)
    git('branch', '-q', '--track', 'feat', 'origin/feat', cwd=w.vm)
    w.commit(w.mac, 'unpushed on feat')
    extra = w.allow() + self.trust()
    _, rows = w.report(extra)
    pid = kinds(rows, 'ASK-PUSH', 'feat')[0]['id']
    d = w.driver(extra)
    d.transport = DeleteFirst(w.tmp)
    code = d.apply([pid], as_json=True)
    out = json.loads(w.out.getvalue())['rows']
    self.assertEqual(code, 1)
    self.assertIn('remote branch is gone', kinds(out, 'REFUSED')[0]['text'])
    self.assertEqual(git('branch', '--list', 'feat', cwd=w.origin), '')

  def test_vm_push_of_a_trusted_repo_still_runs_the_gate(self):
    new = self.w.commit(self.w.vm, 'vm work')
    count, extra = self.counting_gate()
    extra += self.trust()
    _, rows = self.w.report(extra)
    ask = kinds(rows, 'ASK-PUSH', 'main')[0]
    self.assertFalse(ask['trusted'])
    code, out = self.w.apply(extra, push=[ask['id']])
    self.assertEqual(code, 0, out)
    self.assertEqual(self.w.origin_tip(), new)
    self.assertEqual(self.calls(count), 1)

  def test_untrusted_mac_id_is_rejected_by_push(self):
    self.w.commit(self.w.mac, 'mac work')
    _, rows = self.w.report(self.w.allow())
    self.assertIsNone(kinds(rows, 'ASK-PUSH')[0]['id'])
    with self.assertRaisesRegex(rs.Error, 'names no ASK-PUSH row'):
      self.w.driver(self.w.allow()).apply(['origin:main:mac'])

  def test_vm_push_of_a_branch_not_checked_out_is_refused(self):
    self.side_branch()
    git('fetch', '-q', 'origin', cwd=self.w.mac)
    git('branch', '-q', '-f', 'side', 'origin/side', cwd=self.w.mac)
    git('fetch', '-q', 'origin', cwd=self.w.vm)
    git('branch', '-q', '-f', 'side', 'origin/side', cwd=self.w.vm)
    git('checkout', '-q', 'side', cwd=self.w.vm)
    self.w.commit(self.w.vm, 'unpushed side')
    git('checkout', '-q', 'main', cwd=self.w.vm)
    before = self.w.origin_tip('side')
    extra = self.w.allow()
    _, rows = self.w.report(extra)
    ask = kinds(rows, 'ASK-PUSH', 'side')[0]
    code, out = self.w.apply(extra, push=[ask['id']])
    self.assertEqual(code, 1)
    self.assertIn('not the pushed', kinds(out, 'REFUSED')[0]['text'])
    self.assertEqual(self.w.origin_tip('side'), before)

  def test_follow_side_that_changed_before_apply_refuses_the_push(self):
    self.w.commit(self.w.vm, 'unpushed')
    before = self.w.origin_tip()
    extra = self.w.allow()
    _, rows = self.w.report(extra)
    self.w.commit(self.w.mac, 'late mac work')
    code, out = self.w.apply(extra, push=[kinds(rows, 'ASK-PUSH')[0]['id']])
    self.assertEqual(code, 1)
    self.assertIn('mac tip changed', kinds(out, 'REFUSED')[0]['text'])
    self.assertEqual(self.w.origin_tip(), before)

  def test_dirt_that_appears_after_the_report_refuses(self):
    self.w.commit(self.w.vm, 'vm work')
    git('push', '-q', 'origin', 'main', cwd=self.w.vm)
    before = self.w.tip(self.w.mac)
    _, rows = self.w.report()
    self.assertEqual(len(kinds(rows, 'AUTO', 'main')), 1)
    with open(os.path.join(self.w.mac, 'f1.txt'), 'a') as f:
      f.write('edit\n')
    code, out = self.w.apply()
    self.assertEqual(code, 1)
    self.assertIn('tracked changes', kinds(out, 'REFUSED')[0]['text'])
    self.assertEqual(self.w.tip(self.w.mac), before)

  def test_follow_side_dirt_shows_both_rows(self):
    self.w.commit(self.w.vm, 'unpushed')
    with open(os.path.join(self.w.mac, 'f1.txt'), 'a') as f:
      f.write('edit\n')
    _, rows = self.w.report()
    self.assertEqual(len(kinds(rows, 'ASK-PUSH', 'main')), 1)
    self.assertEqual([r['machine'] for r in kinds(rows, 'ASK-DIRTY', 'main')],
                     ['mac'])

  def test_branch_not_checked_out_fast_forwards_exactly(self):
    _, _, top = self.side_branch()
    _, rows = self.w.report()
    auto = kinds(rows, 'AUTO', 'side')
    self.assertEqual([(r['machine'], r['to']) for r in auto], [('mac', top)])
    code, out = self.w.apply()
    self.assertEqual(code, 0, out)
    self.assertEqual(self.w.tip(self.w.mac, 'refs/heads/side'), top)

  def test_not_checked_out_move_stops_at_the_planned_tip(self):
    base, mid, top = self.side_branch()
    job = self.mac_job()
    inv = rs.take_inventory(dict(job, want={}), do_fetch=False)
    res = rs.do_action({'aid': '0', 'op': 'ff', 'key': rs.normalize_url(
        self.w.origin), 'branch': 'side', 'from': base, 'to': mid}, inv, job)
    self.assertTrue(res['ok'], res)
    self.assertEqual(self.w.tip(self.w.mac, 'refs/heads/side'), mid)

  def test_merge_refuses_when_the_worktree_changed_branch(self):
    self.w.commit(self.w.vm, 'vm work')
    git('push', '-q', 'origin', 'main', cwd=self.w.vm)
    job = self.mac_job()
    inv = rs.take_inventory(dict(job, want={}), do_fetch=False)
    old = self.w.tip(self.w.mac)
    git('checkout', '-q', '-b', 'other', cwd=self.w.mac)
    res = rs.do_action({'aid': '0', 'op': 'ff', 'key': rs.normalize_url(
        self.w.origin), 'branch': 'main', 'from': old,
        'to': self.w.origin_tip()}, inv, job)
    self.assertFalse(res['ok'])
    self.assertEqual(self.w.tip(self.w.mac, 'refs/heads/other'), old)
    self.assertEqual(self.w.tip(self.w.mac, 'refs/heads/main'), old)

  def test_a_mid_rebase_clone_is_skipped(self):
    self.w.commit(self.w.seed, 'second')
    git('push', '-q', 'origin', 'main', cwd=self.w.seed)
    git('pull', '-q', '--ff-only', cwd=self.w.mac)
    git('pull', '-q', '--ff-only', cwd=self.w.vm)
    self.w.commit(self.w.vm, 'third')
    git('push', '-q', 'origin', 'main', cwd=self.w.vm)
    subprocess.run(['git', 'rebase', '-x', 'false', 'HEAD~1'], cwd=self.w.mac,
                   capture_output=True)
    before = self.w.tip(self.w.mac, 'refs/heads/main')
    _, rows = self.w.report()
    skipped = kinds(rows, 'SKIPPED', 'main')
    self.assertEqual([r['machine'] for r in skipped], ['mac'])
    self.assertIn('mid-rebase', skipped[0]['text'])
    self.w.apply()
    self.assertEqual(self.w.tip(self.w.mac, 'refs/heads/main'), before)

  def test_a_branch_checked_out_outside_the_scan_is_skipped(self):
    base, _, _ = self.side_branch()
    outside = os.path.join(self.w.tmp, 'outside')
    git('worktree', 'add', '-q', outside, 'side', cwd=self.w.mac)
    _, rows = self.w.report()
    skipped = kinds(rows, 'SKIPPED', 'side')
    self.assertEqual([r['machine'] for r in skipped], ['mac'])
    self.assertIn('outside the scan', skipped[0]['text'])
    self.w.apply()
    self.assertEqual(self.w.tip(outside), base)

  def test_push_never_recreates_a_deleted_remote_branch(self):
    git('checkout', '-q', '-b', 'gone', cwd=self.w.vm)
    git('push', '-q', '-u', 'origin', 'gone', cwd=self.w.vm)
    sha = self.w.commit(self.w.vm, 'on gone')
    git('push', '-q', 'origin', '--delete', 'gone', cwd=self.w.seed)
    job = self.w.driver().job('vm')
    inv = rs.take_inventory(dict(job, want={}), do_fetch=False)
    res = rs.do_action({'aid': '0', 'op': 'push', 'key': rs.normalize_url(
        self.w.origin), 'branch': 'gone', 'from': sha, 'to': sha}, inv, job)
    self.assertFalse(res['ok'])
    self.assertIn('gone', res['msg'])
    self.assertEqual(git('branch', '--list', 'gone', cwd=self.w.origin), '')

  def test_after_hook_expands_a_leading_tilde(self):
    mark = os.path.join(self.w.tmp, 'argv0')
    job = self.w.driver().job('mac', hooks=[{
        'key': rs.normalize_url(self.w.origin),
        'argv': ['/bin/sh', '-c', 'printf %s "$0" > ' + mark, '~/x']}])
    res = rs.agent_after(job)
    self.assertTrue(res['hooks'][0]['ok'], res)
    with open(mark) as f:
      self.assertEqual(f.read(), os.path.expanduser('~/x'))

  def test_a_malformed_mac_result_is_an_error_not_a_crash(self):
    self.w.commit(self.w.vm, 'vm work')
    git('push', '-q', 'origin', 'main', cwd=self.w.vm)
    self.w.report()
    d = self.w.driver()
    d.transport = MalformedApply(self.w.tmp)
    code = d.apply([], as_json=True)
    out = json.loads(self.w.out.getvalue())['rows']
    self.assertEqual(code, 2)
    self.assertIn('malformed', kinds(out, 'FAILED')[0]['text'])

  def test_a_malformed_after_result_is_reported(self):
    d = self.w.driver('after %s mac /bin/true\n' % self.w.origin)
    d.transport = MalformedApply(self.w.tmp)
    out = d.after({(rs.normalize_url(self.w.origin), 'mac')})
    self.assertIn('malformed', kinds(out, 'FAILED')[0]['text'])


class CommittedScript(unittest.TestCase):

  def test_drift_from_the_committed_copy_is_refused(self):
    d = os.path.realpath(tempfile.mkdtemp())
    self.addCleanup(shutil.rmtree, d, True)
    git('init', '-q', '-b', 'main', d)
    path = os.path.join(d, 'tool')
    with open(path, 'w') as f:
      f.write('one\n')
    git('add', 'tool', cwd=d)
    git('commit', '-q', '-m', 'tool', cwd=d)
    self.assertEqual(rs.committed_script(path), b'one\n')
    with open(path, 'w') as f:
      f.write('two\n')
    with self.assertRaisesRegex(rs.Error, 'differs from its committed copy'):
      rs.committed_script(path)


class Config(unittest.TestCase):

  def test_push_trust_is_a_normalized_list(self):
    a = self.write('mac-socket /x\npush-trust git@example.com:o/one.git\n')
    b = self.write('push-trust https://example.com/o/two\n')
    self.assertEqual(rs.parse_config([a, b]).trust,
                     {'example.com/o/one', 'example.com/o/two'})

  def write(self, text, name='repos.list'):
    d = tempfile.mkdtemp()
    self.addCleanup(shutil.rmtree, d, True)
    path = os.path.join(d, name)
    with open(path, 'w') as f:
      f.write(text)
    return path

  def test_19_unknown_keyword_is_an_error(self):
    with self.assertRaisesRegex(rs.Error, 'unknown keyword'):
      rs.parse_config([self.write('mac-socket /x\nrepos git@example.com:o/r\n')])

  def test_19_missing_mac_socket_is_an_error(self):
    with self.assertRaisesRegex(rs.Error, 'mac-socket'):
      rs.parse_config([self.write('repo git@example.com:o/r\n')])

  def test_19_later_overlay_wins_and_lists_add_up(self):
    a = self.write('mac-socket /a  # first\nmac-python /usr/bin/python3\n'
                   'repo git@example.com:o/one.git\n')
    b = self.write('mac-socket /b\nrepo https://example.com/o/two\n')
    cfg = rs.parse_config([a, b])
    self.assertEqual(cfg.mac_socket, '/b')
    self.assertEqual(cfg.mac_python, '/usr/bin/python3')
    self.assertEqual(cfg.repos, ['example.com/o/one', 'example.com/o/two'])

  def test_19_wrong_field_count_is_an_error(self):
    with self.assertRaisesRegex(rs.Error, 'takes'):
      rs.parse_config([self.write('mac-socket /x\nroot ~/only-one\n')])

  def test_19_unsafe_mac_python_is_an_error(self):
    with self.assertRaisesRegex(rs.Error, 'mac-python'):
      rs.parse_config([self.write('mac-socket /x\nmac-python py;rm\n')])

  def test_config_paths_follow_order(self):
    d = tempfile.mkdtemp()
    self.addCleanup(shutil.rmtree, d, True)
    for name in ('b', 'a'):
      os.makedirs(os.path.join(d, name, 'repo-sync'))
      open(os.path.join(d, name, 'repo-sync', 'repos.list'), 'w').close()
    with open(os.path.join(d, '.order'), 'w') as f:
      f.write('# comment\nb\na\n')
    self.assertEqual([p.split(os.sep)[-3] for p in rs.config_paths(d)],
                     ['b', 'a'])


class FakeEmacs:
  """Answers evals from a script of replies, and records every eval."""

  def __init__(self, replies):
    self.replies = list(replies)
    self.forms = []

  def __call__(self, form):
    self.forms.append(form)
    reply = self.replies.pop(0)
    if reply == 'TIMEOUT':
      return rs.Result(None, '', '', timed_out=True)
    return rs.Result(0, reply + '\n', '')


class Transport(unittest.TestCase):

  def setUp(self):
    self.state = tempfile.mkdtemp()
    self.addCleanup(shutil.rmtree, self.state, True)
    self.sock = os.path.join(self.state, 'sock')
    open(self.sock, 'w').close()

  def transport(self, emacs, **kw):
    self.sleeps = []
    return rs.EmacsTransport(self.sock, '/usr/bin/python3', '/usr/bin:/bin',
                             b'#!/usr/bin/env python3\n', self.state,
                             evaluate=emacs, sleep=self.sleeps.append, **kw)

  def test_20_pending_then_done_decodes_exactly(self):
    data = {'x': [1, 'two', None], 'subject': 'café'}
    body = {'ok': True, 'version': rs.VERSION, 'data': data}
    b64 = base64.b64encode(gzip.compress(json.dumps(body).encode())).decode()
    emacs = FakeEmacs(['t', '"started"', '"PENDING"', '"%s"' % b64, '"ok"'])
    t = self.transport(emacs)
    self.assertEqual(t.run_job('inventory', {'k': 1}), data)
    self.assertEqual(len(emacs.forms), 5)
    self.assertEqual(self.sleeps, [rs.POLL_INTERVAL])
    self.assertIn('start-process', emacs.forms[1])
    self.assertIn('delete-directory', emacs.forms[4])
    tag = re.search(r'repo-sync-([0-9a-f]{16})', emacs.forms[1]).group(1)
    with open(os.path.join(self.state, 'jobs', tag + '-inventory.json')) as f:
      self.assertEqual(json.load(f), {'k': 1})

  def test_20_timeout_on_the_first_eval_makes_no_second_eval(self):
    emacs = FakeEmacs(['TIMEOUT', 't'])
    t = self.transport(emacs)
    with self.assertRaises(rs.TransportError) as cm:
      t.run_job('inventory', {})
    self.assertEqual(cm.exception.state, 'BUSY')
    with self.assertRaises(rs.TransportError):
      t.run_job('inventory', {})
    self.assertEqual(len(emacs.forms), 1)

  def test_20_deadline_leaves_the_job_running(self):
    now = [0]
    emacs = FakeEmacs(['t', '"started"'] + ['"PENDING"'] * 5)

    def clock():
      now[0] += 100
      return now[0]
    t = self.transport(emacs, clock=clock, deadline=250)
    with self.assertRaises(rs.TransportError) as cm:
      t.run_job('inventory', {})
    self.assertEqual(cm.exception.state, 'TIMEOUT')
    self.assertRegex(str(cm.exception), 'job [0-9a-f]{16} is still running')
    self.assertFalse(any('delete-directory' in f for f in emacs.forms))

  def test_20_missing_socket_makes_no_eval(self):
    emacs = FakeEmacs([])
    t = self.transport(emacs)
    t.socket = os.path.join(self.state, 'absent')
    with self.assertRaises(rs.TransportError) as cm:
      t.run_job('inventory', {})
    self.assertEqual(cm.exception.state, 'UNREACHABLE')
    self.assertEqual(emacs.forms, [])

  def test_elisp_string_quotes_backslash_and_quote(self):
    self.assertEqual(rs.elisp_string('a"b\\c'), '"a\\"b\\\\c"')
    self.assertEqual(rs.parse_lisp_string('"a\\"b\\\\c"\n'), 'a"b\\c')


class ShellEmacs:
  """Plays the three eval forms by running the launch script with /bin/sh."""

  def __init__(self):
    self.forms = []
    self.procs = []

  def __call__(self, form):
    self.forms.append(form)
    if form == 't':
      return rs.Result(0, 't\n', '')
    m = re.search(r'"/bin/sh" "-c" (".*")\) nil\) "started"\)$', form, re.S)
    if m:
      self.procs.append(subprocess.Popen(
          ['/bin/sh', '-c', rs.parse_lisp_string(m.group(1))], cwd='/tmp',
          start_new_session=True))
      return rs.Result(0, '"started"\n', '')
    m = re.search(r'"(/tmp/repo-sync-[0-9a-f]{16}/)"', form)
    d = m.group(1)
    if 'delete-directory' in form:
      shutil.rmtree(d)
      return rs.Result(0, '"ok"\n', '')
    if not os.path.exists(d + 'rc'):
      return rs.Result(0, '"PENDING"\n', '')
    if not os.path.exists(d + 'result.json.gz'):
      with open(d + 'rc') as f:
        return rs.Result(0, '"NORESULT %s"\n' % f.read().strip(), '')
    with open(d + 'result.json.gz', 'rb') as f:
      return rs.Result(0, '"%s"\n' % base64.b64encode(f.read()).decode(), '')


class LaunchScript(unittest.TestCase):
  """The mac launch script, run for real on this machine."""

  def setUp(self):
    self.state = tempfile.mkdtemp()
    self.addCleanup(shutil.rmtree, self.state, True)
    self.sock = os.path.join(self.state, 'sock')
    open(self.sock, 'w').close()
    with open(SCRIPT, 'rb') as f:
      self.script = f.read()

  def run_version(self, script):
    emacs = ShellEmacs()
    t = rs.EmacsTransport(self.sock, sys.executable, '/usr/bin:/bin', script,
                          self.state, evaluate=emacs, sleep=time.sleep,
                          interval=0.1, deadline=60)
    try:
      return t.run_job('version', {}), emacs
    finally:
      for p in emacs.procs:
        p.wait(30)

  def test_version_job_round_trips_and_cleans_up(self):
    got, emacs = self.run_version(self.script)
    self.assertEqual(got['version'], rs.VERSION)
    tag = re.search(r'repo-sync-([0-9a-f]{16})', emacs.forms[1]).group(1)
    self.assertFalse(os.path.exists('/tmp/repo-sync-' + tag))

  def test_sha_mismatch_runs_nothing(self):
    emacs = ShellEmacs()
    t = rs.EmacsTransport(self.sock, sys.executable, '/usr/bin:/bin',
                          self.script, self.state, evaluate=emacs,
                          sleep=time.sleep, interval=0.1, deadline=60)
    real = rs.launch_script
    with mock.patch.object(rs, 'launch_script',
                           lambda *a: real(*a[:4], '0' * 64, *a[5:])):
      with self.assertRaisesRegex(rs.Error, 'wrote no result'):
        t.run_job('version', {})
    for p in emacs.procs:
      p.wait(30)
    tag = re.search(r'repo-sync-([0-9a-f]{16})', emacs.forms[1]).group(1)
    d = '/tmp/repo-sync-' + tag
    self.assertFalse(os.path.exists(os.path.join(d, 'agent.log')))
    shutil.rmtree(d, True)


class Validate(unittest.TestCase):

  def inv(self):
    return {'home': '/Users/m', 'roots': ['/Users/m/p'], 'order': None,
            'includes': None, 'fetched': [1, 1],
            'repos': {'example.com/o/r': [{
                'top': '/Users/m/p/r', 'fetch': None, 'dropped': {},
                'worktrees': [{'path': '/Users/m/p/r', 'branch': 'main',
                               'email': None, 'tracked': [], 'untracked': []}],
                'branches': {'main': {'tip': 'a' * 40, 'origin': 'a' * 40,
                                      'log': [['a' * 40, '2026-01-01',
                                               'x\x1b[31my']]}}}]}}

  def validate(self, inv, **kw):
    kw.setdefault('check_name', lambda n: True)
    return rs.validate_inventory(inv, ['~/p'], **kw)

  def test_good_inventory_passes_and_is_cleaned(self):
    inv = self.validate(self.inv())
    log = inv['repos']['example.com/o/r'][0]['branches']['main']['log']
    self.assertEqual(log[0][2], 'x[31my')

  def test_path_outside_the_roots_is_rejected(self):
    inv = self.inv()
    inv['repos']['example.com/o/r'][0]['worktrees'][0]['path'] = '/etc'
    with self.assertRaises(rs.Error):
      self.validate(inv)

  def test_reported_roots_do_not_widen_the_configured_ones(self):
    inv = self.inv()
    inv['roots'].append('/etc')
    inv['repos']['example.com/o/r'][0]['top'] = '/etc/r'
    with self.assertRaisesRegex(rs.Error, 'outside the mac roots'):
      self.validate(inv)

  def test_bad_sha_is_rejected(self):
    inv = self.inv()
    inv['repos']['example.com/o/r'][0]['branches']['main']['tip'] = 'HEAD'
    with self.assertRaises(rs.Error):
      self.validate(inv)

  def test_bad_branch_name_is_dropped(self):
    inv = self.inv()
    br = inv['repos']['example.com/o/r'][0]['branches']
    br['-x..y'] = dict(br['main'])
    inv = rs.validate_inventory(inv, ['~/p'])
    self.assertEqual(sorted(inv['repos']['example.com/o/r'][0]['branches']),
                     ['main'])


if __name__ == '__main__':
  unittest.main()
