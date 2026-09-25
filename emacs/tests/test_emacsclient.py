"""Tests for the $EDITOR wrapper's command-line decision.

Every case calls `build_args', which returns a list and opens nothing.  That
is deliberate and it is the repo's rule: test the decision, never perform the
effect.  Running the wrapper for real would open a file in David's live Emacs.

The environment is passed in rather than patched, so a case states the host it
describes instead of mutating os.environ and hoping the next case restores it.
"""

import importlib.util
import pathlib
import unittest

WRAPPER = pathlib.Path(__file__).resolve().parent.parent / 'emacsclient.py'

_spec = importlib.util.spec_from_file_location('emacsclient_wrapper', WRAPPER)
emacsclient = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(emacsclient)

CLIENT = '/usr/bin/emacsclient'
SOCKET = '/home/tester/.ssh/emacs-server'
PREFIX = [CLIENT, '-s', SOCKET]


def build(passthrough, ssh=False):
  return emacsclient.build_args(passthrough, CLIENT, SOCKET, ssh,
                                'testhost', 'tester')


class SocketIsAlwaysPassed(unittest.TestCase):
  """-s <socket> leads every command, which is why one path serves both hosts."""

  def test_local_open(self):
    self.assertEqual(build(['/tmp/f.txt'])[:3], PREFIX)

  def test_remote_open(self):
    self.assertEqual(build(['/tmp/f.txt'], ssh=True)[:3], PREFIX)

  def test_eval(self):
    self.assertEqual(build(['-e', '(emacs-version)'])[:3], PREFIX)


class LocalShell(unittest.TestCase):
  """No SSH_CLIENT: the path is already reachable, so it goes through as-is."""

  def test_plain_path_is_unchanged(self):
    self.assertEqual(build(['/tmp/f.txt']), PREFIX + ['/tmp/f.txt'])

  def test_flags_keep_their_order_before_the_file(self):
    self.assertEqual(build(['-n', '/tmp/f.txt']), PREFIX + ['-n', '/tmp/f.txt'])

  def test_relative_path_is_unchanged(self):
    self.assertEqual(build(['f.txt']), PREFIX + ['f.txt'])


class RemoteShell(unittest.TestCase):
  """Under SSH_CLIENT the local Emacs cannot see the file, so it gets a TRAMP
  path that fetches it back over scp."""

  def test_path_is_rewritten(self):
    self.assertEqual(build(['/tmp/f.txt'], ssh=True),
                     PREFIX + ['/scp:tester@testhost:/tmp/f.txt'])

  def test_flags_survive_the_rewrite(self):
    self.assertEqual(build(['-n', '/tmp/f.txt'], ssh=True),
                     PREFIX + ['-n', '/scp:tester@testhost:/tmp/f.txt'])


class AlreadyTramp(unittest.TestCase):
  """A path that carries a TRAMP prefix is never wrapped again.

  Double-wrapping produces /scp:h:/-:h:/path, and the far Emacs reads the inner
  path as a bogus localname.  The commit gate hands over /ssh: paths, so this
  is the case that breaks it when it regresses.
  """

  def test_ssh_prefix_survives_a_remote_shell(self):
    self.assertEqual(build(['/ssh:box:/tmp/f.txt'], ssh=True),
                     PREFIX + ['/ssh:box:/tmp/f.txt'])

  def test_scp_prefix_survives_a_remote_shell(self):
    self.assertEqual(build(['/scp:box:/tmp/f.txt'], ssh=True),
                     PREFIX + ['/scp:box:/tmp/f.txt'])

  def test_dash_method_survives_a_remote_shell(self):
    self.assertEqual(build(['/-:box:/tmp/f.txt'], ssh=True),
                     PREFIX + ['/-:box:/tmp/f.txt'])

  def test_a_plain_absolute_path_is_not_mistaken_for_tramp(self):
    self.assertEqual(build(['/tmp/f.txt'], ssh=True),
                     PREFIX + ['/scp:tester@testhost:/tmp/f.txt'])


class EvalIsPassedThroughWhole(unittest.TestCase):
  """With -e/--eval the trailing arguments are elisp forms, not paths.

  Rewriting one would turn an expression into a filename.  A form can also look
  like a path, which is why the check is on the flag and not on the argument.
  """

  def test_short_flag(self):
    self.assertEqual(build(['-e', '(emacs-version)'], ssh=True),
                     PREFIX + ['-e', '(emacs-version)'])

  def test_long_flag(self):
    self.assertEqual(build(['--eval', '(emacs-version)'], ssh=True),
                     PREFIX + ['--eval', '(emacs-version)'])

  def test_joined_long_flag(self):
    self.assertEqual(build(['--eval=(emacs-version)'], ssh=True),
                     PREFIX + ['--eval=(emacs-version)'])

  def test_a_form_naming_a_file_is_not_rewritten(self):
    self.assertEqual(build(['-e', '(find-file "/tmp/f.txt")'], ssh=True),
                     PREFIX + ['-e', '(find-file "/tmp/f.txt")'])


if __name__ == '__main__':
  unittest.main()
