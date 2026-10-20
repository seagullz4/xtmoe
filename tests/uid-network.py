#!/usr/bin/env python3
"""Pure policy regression tests. Never calls Android services or changes maps."""
import copy
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('uid_network', Path(__file__).resolve().parent.parent/'src/lib/xtmoe-uid-network.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class FakePolicy:
    def __init__(self):
        self.flags = {}
        self.calls = []
        self.mode = True
        self.fail = None

    def enabled(self):
        return self.mode

    def allowed(self, uid):
        return bool(self.flags.get(uid, 0) & m.BIT)

    def set(self, uid, enabled):
        self.calls.append((uid, enabled))
        if self.fail == enabled:
            raise RuntimeError('API failure')
        self.flags[uid] = (self.flags.get(uid, 0) | m.BIT) if enabled else (self.flags.get(uid, 0) & ~m.BIT)


class Ownership(unittest.TestCase):
    def setUp(self):
        self.policy = FakePolicy()
        self.state = {}
        self.saved = []
        self.leases = m.Leases(self.policy, self.state, lambda: self.saved.append(copy.deepcopy(self.state)))

    def test_acquire_and_revoke_only_owned_bit(self):
        self.policy.flags[65532] = 0x80
        self.leases.reconcile({65532: {'A'}})
        self.assertTrue(self.policy.allowed(65532))
        self.assertEqual(self.saved[0]['leases']['65532'], {'owned': True, 'owners': []})
        self.leases.reconcile({})
        self.assertEqual(self.policy.flags[65532], 0x80)
        self.assertEqual(self.state['leases'], {})

    def test_existing_authorization_is_never_revoked(self):
        self.policy.flags[65532] = m.BIT | 0x80
        self.leases.reconcile({65532: {'A'}})
        self.leases.reconcile({})
        self.assertEqual(self.policy.calls, [])
        self.assertTrue(self.policy.allowed(65532))

    def test_two_containers_share_and_last_release_revokes(self):
        self.leases.reconcile({65532: {'A', 'B'}})
        self.leases.reconcile({65532: {'B'}})
        self.assertEqual(self.policy.calls, [(65532, True)])
        self.assertEqual(self.state['leases']['65532']['owners'], ['B'])
        self.leases.reconcile({})
        self.assertEqual(self.policy.calls[-1], (65532, False))

    def test_disjoint_containers_do_not_release_each_other(self):
        self.leases.reconcile({65532: {'A'}, 65531: {'B'}})
        self.leases.reconcile({65531: {'B'}})
        self.assertFalse(self.policy.allowed(65532))
        self.assertTrue(self.policy.allowed(65531))

    def test_acquisition_failure_is_journalled_before_call(self):
        self.policy.fail = True
        with self.assertRaises(RuntimeError):
            self.leases.reconcile({65532: {'A'}})
        self.assertTrue(self.state['leases']['65532']['owned'])
        self.policy.fail = None
        self.leases.reconcile({})
        self.assertEqual(self.state['leases'], {})

    def test_release_failure_retains_recoverable_journal(self):
        self.leases.reconcile({65532: {'A'}})
        self.policy.fail = False
        with self.assertRaises(RuntimeError):
            self.leases.reconcile({})
        self.assertIn('65532', self.state['leases'])
        self.policy.fail = None
        self.leases.reconcile({})
        self.assertFalse(self.policy.allowed(65532))

    def test_restart_after_api_call_recovers_owned_grant(self):
        self.state['leases'] = {'65532': {'owned': True, 'owners': []}}
        self.policy.flags[65532] = m.BIT
        self.leases.reconcile({})
        self.assertFalse(self.policy.allowed(65532))

    def test_refresh_readds_only_own_lost_permission(self):
        self.leases.reconcile({65532: {'A'}})
        self.policy.flags[65532] = 0x80
        self.leases.reconcile({65532: {'A'}})
        self.assertEqual(self.policy.flags[65532], 0x80 | m.BIT)

    def test_original_external_permission_is_not_recreated(self):
        self.policy.flags[65532] = m.BIT
        self.leases.reconcile({65532: {'A'}})
        self.policy.flags[65532] = 0
        self.leases.reconcile({65532: {'A'}})
        self.assertEqual(self.policy.calls, [])


class ApiSafety(unittest.TestCase):
    def test_unsupported_backend_can_unregister_without_faking_cleanup(self):
        state = {'registrations': {'A': {}}, 'leases': {'65532': {'owned': True, 'owners': ['A']}}}
        self.assertEqual(m.unregister_offline(state, 'A'), ['65532'])
        self.assertEqual(state['registrations'], {})
        self.assertIn('65532', state['leases'])

    def test_offline_unregister_preserves_other_owners_and_external_rules(self):
        state = {'registrations': {'A': {}, 'B': {}}, 'leases': {
            '65532': {'owned': True, 'owners': ['A', 'B']},
            '65531': {'owned': False, 'owners': ['A']}}}
        self.assertEqual(m.unregister_offline(state, 'A'), [])
        self.assertEqual(state['leases'], {'65532': {'owned': True, 'owners': ['B']}})

    def test_forbids_direct_bpf_updates(self):
        backend = m.ReadMap.__new__(m.ReadMap)
        for operation in (0, 2, 3, 4, 5):
            with self.assertRaises(m.Unsupported):
                backend.call(operation, b'')

    def test_api_failure_has_no_fallback(self):
        p = m.Policy.__new__(m.Policy)
        p.code = 183
        with patch.object(m.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'Exception: permission denied')) as run:
            with self.assertRaises(m.Unsupported):
                p.set(65532, True)
            self.assertEqual(run.call_count, 1)
            args = run.call_args.args[0]
            self.assertEqual(args, ['/system/bin/service', 'call', 'connectivity', '183', 'i32', '4', 'i32', '65532', 'i32', '1'])

    def test_api_success_requires_readback(self):
        p = m.Policy.__new__(m.Policy)
        p.code = 83
        with patch.object(m.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, "Result: Parcel(00000000 '....')")):
            p.allowed = lambda _: False
            with self.assertRaises(m.Unsupported):
                p.set(65532, True)
            p.allowed = lambda _: True
            p.set(65532, True)

    def test_old_android_fails_without_mutations(self):
        with patch.object(m.subprocess, 'check_output', return_value='32'):
            with self.assertRaises(m.Unsupported):
                m.framework_transaction()

    def test_systemd_identity_loss_removes_owner(self):
        class Store:
            state = {'registrations': {'A': {'pid': 1}}, 'leases': {'65532': {'owned': True, 'owners': ['A']}}}
            def save(self):
                pass
        p = FakePolicy()
        p.flags[65532] = m.BIT
        with patch.object(m, 'alive', return_value=False):
            m.cycle(Store(), p, set())
        self.assertFalse(p.allowed(65532))
        self.assertEqual(Store.state['registrations'], {})


class ProcessScope(unittest.TestCase):
    class Node:
        def __init__(self, path, tree):
            self.path, self.tree = path, tree
            self.name = path.rsplit('/', 1)[-1]

        def __truediv__(self, value):
            return ProcessScope.Node(self.path+'/'+str(value), self.tree)

        def iterdir(self):
            return iter(ProcessScope.Node(x, self.tree) for x in self.tree[self.path])

        def read_text(self):
            return self.tree[self.path]

    def test_only_private_namespace_non_app_non_system_thread_uids(self):
        tree = {'/proc': ['/proc/1', '/proc/2', '/proc/3'],
                '/proc/2/task': ['/proc/2/task/2', '/proc/2/task/20', '/proc/2/task/21'],
                '/proc/3/task': ['/proc/3/task/3', '/proc/3/task/30'],
                '/proc/2/task/2/status': 'Uid:\t65532\t65532\t65532\t65532\n',
                '/proc/2/task/20/status': 'Uid:\t10200\t10200\t10200\t10200\n',
                '/proc/2/task/21/status': 'Uid:\t0\t0\t0\t0\n',
                '/proc/3/task/3/status': 'Uid:\t1000\t1000\t1000\t1000\n',
                '/proc/3/task/30/status': 'Uid:\t65533\t65533\t65533\t65533\n'}
        with patch.object(m, 'alive', return_value=True), patch.object(m, 'identity', return_value='birth'), \
                patch.object(m, 'namespace_member', side_effect=lambda pid, _: pid != '1'), \
                patch.object(m, 'Path', side_effect=lambda x: self.Node(x, tree)):
            self.assertEqual(m.scan({'namespace': 123}, {10200}), {65532, 65533})

    def test_pid_reuse_is_not_authorized(self):
        tree = {'/proc': ['/proc/2'], '/proc/2/task': ['/proc/2/task/2'],
                '/proc/2/task/2/status': 'Uid:\t65532\t65532\t65532\t65532\n'}
        with patch.object(m, 'alive', return_value=True), patch.object(m, 'identity', side_effect=['old', 'new']), \
                patch.object(m, 'namespace_member', return_value=True), \
                patch.object(m, 'Path', side_effect=lambda x: self.Node(x, tree)):
            self.assertEqual(m.scan({'namespace': 123}, set()), set())

    def test_dead_namespace_cannot_grant(self):
        with patch.object(m, 'alive', return_value=False):
            self.assertEqual(m.scan({'namespace': 123}, set()), set())

    def test_disabled_global_mode_does_not_grant_and_releases_owned(self):
        class Store:
            state = {'registrations': {'A': {'pid': 1}}, 'leases': {'65532': {'owned': True, 'owners': ['A']}}}
            def save(self):
                pass
        p = FakePolicy()
        p.mode = False
        p.flags[65532] = m.BIT
        with patch.object(m, 'alive', return_value=True), patch.object(m, 'scan') as scan:
            m.cycle(Store(), p, set())
            scan.assert_not_called()
        self.assertFalse(p.allowed(65532))


if __name__ == '__main__':
    unittest.main(verbosity=2)
