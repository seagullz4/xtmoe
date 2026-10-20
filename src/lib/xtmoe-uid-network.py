#!/usr/bin/env python3
"""Opt-in, UID-global restricted-network leases for private systemd Chroots.

Read BPF maps only. Writes go through ConnectivityService.setUidFirewallRule,
whose transaction/signature/constants are discovered from this device's DEX.
No global chain toggles, direct map writes, Docker socket or token inspection.
"""
import argparse
import ctypes
try:
    import fcntl
except ImportError:  # Allow pure-policy tests on Windows; main still refuses it.
    fcntl = None
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import struct
import subprocess
import sys
import time
import zipfile

STATE = Path('/data/local/tmp/xtmoe-uid-network')
BIT = 1 << 5


class Unsupported(RuntimeError):
    pass


def atomic_json(path, value):
    data = json.dumps(value, sort_keys=True)
    if path.is_file() and not path.is_symlink() and path.read_text() == data:
        return
    tmp = path.with_name(path.name + '.tmp')
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as out:
        out.write(data)
        out.flush()
        os.fsync(out.fileno())
    os.replace(tmp, path)


def load_json(path, default):
    if not path.exists():
        return default
    if path.is_symlink() or not path.is_file():
        raise Unsupported('Unsafe state file: ' + str(path))
    return json.loads(path.read_text())


class Dex:
    """Small metadata reader; never executes code from the framework archive."""
    def __init__(self, data):
        self.d = data
        if not data.startswith(b'dex\n'):
            raise Unsupported('Unsupported framework DEX')
        self.strings = []
        for i in range(self.u(56)):
            p = self.u(self.u(60) + 4 * i)
            _, p = self.leb(p)
            self.strings.append(data[p:data.index(b'\0', p)].decode())
        self.types = [self.strings[self.u(self.u(68) + 4*i)] for i in range(self.u(64))]
        self.fields = []
        for i in range(self.u(80)):
            a, b, c = struct.unpack_from('<HHI', data, self.u(84) + 8*i)
            self.fields.append((self.types[a], self.types[b], self.strings[c]))

    def u(self, p):
        return struct.unpack_from('<I', self.d, p)[0]

    def leb(self, p):
        value = shift = 0
        for _ in range(5):
            b = self.d[p]
            p += 1
            value |= (b & 127) << shift
            if b < 128:
                return value, p
            shift += 7
        raise Unsupported('Invalid DEX integer')

    def constants(self, cls):
        result = {}
        for i in range(self.u(96)):
            p = self.u(100) + 32*i
            if self.types[self.u(p)] != cls or not self.u(p+24) or not self.u(p+28):
                continue
            q = self.u(p+24)
            counts = []
            for _ in range(4):
                n, q = self.leb(q)
                counts.append(n)
            fields, idx = [], 0
            for _ in range(counts[0]):
                diff, q = self.leb(q)
                _, q = self.leb(q)
                idx += diff
                fields.append(self.fields[idx])
            q = self.u(p+28)
            n, q = self.leb(q)
            for k in range(n):
                head = self.d[q]
                q += 1
                typ, size = head & 31, (head >> 5)+1
                if typ == 30:
                    value = None
                elif typ == 31:
                    value = head >> 5
                elif typ in (0, 2, 3, 4, 6, 16, 17, 23, 24, 25, 26, 27):
                    value = int.from_bytes(self.d[q:q+size], 'little', signed=typ in (0, 2, 4, 6))
                    q += size
                else:
                    raise Unsupported('Unsupported framework static metadata')
                result[fields[k][2]] = value
        return result

    def method(self, cls, name):
        for i in range(self.u(88)):
            a, b, c = struct.unpack_from('<HHI', self.d, self.u(92)+8*i)
            if self.types[a] != cls or self.strings[c] != name:
                continue
            p = self.u(76)+12*b
            off = self.u(p+8)
            args = [] if not off else [self.types[struct.unpack_from('<H', self.d, off+4+2*j)[0]] for j in range(self.u(off))]
            return args, self.types[self.u(p+4)]
        return None


def framework_transaction():
    sdk = subprocess.check_output(['/system/bin/getprop', 'ro.build.version.sdk'], text=True).strip()
    if not sdk.isdigit() or not 33 <= int(sdk) <= 35:
        raise Unsupported('UID leases require a verified Android 13-15 framework; no fallback writes')
    path = Path('/apex/com.android.tethering/javalib/framework-connectivity.jar')
    codes, constants, signature = {}, {}, None
    with zipfile.ZipFile(path) as archive:
        for name in archive.namelist():
            if not re.fullmatch(r'classes\d*\.dex', name):
                continue
            dex = Dex(archive.read(name))
            codes.update(dex.constants('Landroid/net/IConnectivityManager$Stub;'))
            constants.update(dex.constants('Landroid/net/ConnectivityManager;'))
            signature = dex.method('Landroid/net/IConnectivityManager;', 'setUidFirewallRule') or signature
    code = codes.get('TRANSACTION_setUidFirewallRule')
    if signature != (['I', 'I', 'I'], 'V') or not isinstance(code, int) or not 1 <= code <= 1000:
        raise Unsupported('Unverified ConnectivityService method metadata')
    if any(constants.get(k) != v for k, v in {'FIREWALL_CHAIN_RESTRICTED': 4, 'FIREWALL_RULE_ALLOW': 1, 'FIREWALL_RULE_DEFAULT': 0}.items()):
        raise Unsupported('Unverified framework firewall constants')
    return code


class ReadMap:
    def __init__(self, name, size):
        machine = os.uname().machine
        numbers = {'aarch64': 280, 'armv7l': 386, 'armv8l': 386, 'x86_64': 321, 'i686': 357}
        if machine not in numbers:
            raise Unsupported('Unsupported BPF syscall ABI')
        self.number = numbers[machine]
        self.libc = ctypes.CDLL(None, use_errno=True)
        path = ctypes.create_string_buffer(('/sys/fs/bpf/netd_shared/map_netd_'+name+'_map').encode())
        self.fd = self.call(7, struct.pack('=QII', ctypes.addressof(path), 0, 8))
        info = ctypes.create_string_buffer(64)
        try:
            self.call(15, struct.pack('=IIQ', self.fd, 64, ctypes.addressof(info)))
            kind, _, key_size, value_size = struct.unpack_from('=IIII', info)
            if kind not in (1, 2) or key_size != 4 or value_size != size:
                raise Unsupported('Unexpected netd map layout')
        except BaseException:
            os.close(self.fd)
            raise
        self.size = size

    def call(self, cmd, raw):
        # These are the only permitted syscall commands: open, lookup, metadata.
        if cmd not in (1, 7, 15):
            raise Unsupported('BPF map writes are forbidden')
        buf = ctypes.create_string_buffer(raw)
        result = self.libc.syscall(self.number, cmd, ctypes.byref(buf), len(raw))
        if result < 0:
            raise OSError(ctypes.get_errno(), os.strerror(ctypes.get_errno()))
        return result

    def get(self, key):
        k = ctypes.c_uint32(key)
        value = ctypes.create_string_buffer(self.size)
        try:
            self.call(1, struct.pack('=IIQQQ', self.fd, 0, ctypes.addressof(k), ctypes.addressof(value), 0))
        except OSError as exc:
            if exc.errno == 2:
                return bytes(self.size)
            raise
        return value.raw


class Policy:
    def __init__(self):
        self.code = framework_transaction()
        self.owner = ReadMap('uid_owner', 8)
        self.config = ReadMap('configuration', 4)

    def enabled(self):
        return bool(struct.unpack('=I', self.config.get(0))[0] & BIT)

    def allowed(self, uid):
        return bool(struct.unpack('=II', self.owner.get(uid))[1] & BIT)

    def set(self, uid, enabled):
        result = subprocess.run(['/system/bin/service', 'call', 'connectivity', str(self.code),
                                 'i32', '4', 'i32', str(uid), 'i32', '1' if enabled else '0'],
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
        if result.returncode or not re.search(r'Parcel\(\s*00000000\s', result.stdout):
            raise Unsupported('ConnectivityService rejected UID rule; no fallback used')
        if self.allowed(uid) != enabled:
            raise Unsupported('UID rule verification failed')


def identity(pid):
    # comm can contain whitespace and parentheses; field 22 follows final ')'.
    return Path(f'/proc/{pid}/stat').read_text().rpartition(')')[2].split()[19]


def binding(container, pid):
    st = os.stat(f'/proc/{pid}/root')
    target = os.stat(container / 'rootfs')
    ns = os.stat(f'/proc/{pid}/ns/pid').st_ino
    if (st.st_dev, st.st_ino) != (target.st_dev, target.st_ino) or ns == os.stat('/proc/1/ns/pid').st_ino:
        raise Unsupported('Only a private systemd PID namespace is supported')
    if Path(f'/proc/{pid}/comm').read_text().strip() not in ('systemd', 'init'):
        raise Unsupported('Namespace owner is not the expected systemd init')
    return {'container': str(container), 'pid': pid, 'birth': identity(pid), 'namespace': ns}


def alive(record):
    try:
        return binding(Path(record['container']), record['pid']) == record
    except (OSError, ValueError, IndexError, Unsupported):
        return False


def namespace_member(pid, ns):
    fd = None
    try:
        fd = os.open(f'/proc/{pid}/ns/pid', os.O_RDONLY)
        for _ in range(32):
            if os.fstat(fd).st_ino == ns:
                return True
            parent = fcntl.ioctl(fd, 0xb702)  # NS_GET_PARENT: kernel-supported namespace ancestry.
            os.close(fd)
            fd = parent
    except OSError:
        return False
    finally:
        if fd is not None:
            os.close(fd)
    return False


def package_uids():
    r = subprocess.run(['/system/bin/cmd', 'package', 'list', 'packages', '-U'],
                       stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
    uids = set(map(int, re.findall(r'\buid:(\d+)\b', r.stdout)))
    if r.returncode or not uids:
        raise Unsupported('Cannot identify Android application UIDs; refusing grants')
    return uids


def scan(record, apps):
    found = set()
    if not alive(record):
        return found
    for proc in Path('/proc').iterdir():
        if not proc.name.isdigit() or not namespace_member(proc.name, record['namespace']):
            continue
        try:
            before = identity(proc.name)
            uids = set()
            for thread in (proc / 'task').iterdir():
                line = next(x for x in (thread / 'status').read_text().splitlines() if x.startswith('Uid:'))
                uid = int(line.split()[4])  # filesystem UID used when creating sockets
                if 10000 <= uid <= 2147483646 and uid not in apps:
                    uids.add(uid)
            if identity(proc.name) == before and alive(record):
                found.update(uids)
                if len(found) > 64:
                    raise Unsupported('More than 64 UID candidates in one Chroot; refusing bulk grants')
        except (OSError, StopIteration, ValueError, IndexError):
            continue
    return found


class Leases:
    def __init__(self, policy, state, save):
        self.policy, self.state, self.save = policy, state, save

    def reconcile(self, wanted):
        leases = self.state.setdefault('leases', {})
        # Journal before acquiring. Restart can recover even if killed after the API call.
        for uid in sorted(wanted):
            key = str(uid)
            if key not in leases:
                leases[key] = {'owned': not self.policy.allowed(uid), 'owners': []}
                self.save()
            lease = leases[key]
            lease['owners'] = sorted(wanted[uid])
            if lease['owned'] and not self.policy.allowed(uid):
                self.policy.set(uid, True)
            self.save()
        for key in list(leases):
            if int(key) in wanted:
                continue
            if leases[key]['owned'] and self.policy.allowed(int(key)):
                self.policy.set(int(key), False)
            del leases[key]
            self.save()


class Store:
    def __init__(self, directory=STATE):
        self.dir = directory
        if directory.is_symlink():
            raise Unsupported('Unsafe UID state directory')
        directory.mkdir(mode=0o700, exist_ok=True)
        st = directory.stat()
        if st.st_uid != os.geteuid() or stat.S_IMODE(st.st_mode) != 0o700:
            raise Unsupported('Unsafe UID state owner/mode')
        self.lock = None

    def __enter__(self):
        self.lock = os.open(self.dir / 'lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        self.path = self.dir / 'state.json'
        self.state = load_json(self.path, {})
        boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
        if self.state.get('boot') != boot:
            # New boot = old kernel maps no longer owned by us; never restore old snapshots.
            self.state = {'version': 1, 'boot': boot, 'registrations': {}, 'leases': {}}
        return self

    def __exit__(self, *args):
        os.close(self.lock)

    def save(self):
        atomic_json(self.path, self.state)


def cycle(store, policy, apps):
    wanted = {}
    for key, record in list(store.state['registrations'].items()):
        if not alive(record):
            del store.state['registrations'][key]
            continue
        if policy.enabled():
            for uid in scan(record, apps):
                wanted.setdefault(uid, set()).add(key)
    Leases(policy, store.state, store.save).reconcile(wanted)
    store.state['restricted_mode'] = policy.enabled()
    store.state['last_error'] = ''
    store.save()


def unregister_offline(state, key):
    """Disable future grants even if a restored config has no supported backend.

    Never claim outstanding owned permissions were removed without readback.
    """
    state['registrations'].pop(key, None)
    pending = []
    for uid, lease in list(state['leases'].items()):
        lease['owners'] = [x for x in lease['owners'] if x != key]
        if not lease['owners']:
            if lease['owned']:
                pending.append(uid)
            else:
                del state['leases'][uid]
    return pending


def container_path(raw):
    p = Path(raw)
    if p.is_symlink() or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}', p.name):
        raise Unsupported('Invalid container path')
    p = p.resolve(strict=True)
    if not str(p.parent).endswith('/files/home/.local/share/xtmoe/chroot'):
        raise Unsupported('Not an XTMOE Chroot')
    marker = p / '.xtmoe-chroot'
    if marker.is_symlink() or marker.read_text().strip() != 'xtmoe-chroot-format-1' or (p/'rootfs').is_symlink():
        raise Unsupported('Invalid Chroot tree')
    return p


def config(container, enabled):
    p = container / '.xtmoe-uid-network'
    if p.is_symlink() or (p.exists() and p.read_text() not in ('enabled=1\n', 'enabled=0\n')):
        raise Unsupported('Unsafe UID-network config')
    tmp = container / '.xtmoe-uid-network.tmp'
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as out:
        out.write('enabled=%d\n' % enabled)
    os.replace(tmp, p)


def daemon():
    store = Store()
    fd = os.open(store.dir/'daemon.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        return
    stopping = False
    def stop(*_):
        nonlocal stopping
        stopping = True
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    policy = Policy()
    apps, ticks = package_uids(), 0
    atomic_json(store.dir/'daemon.json', {'pid': os.getpid(), 'birth': identity(os.getpid())})
    try:
        while not stopping:
            try:
                if ticks and ticks % 15 == 0:
                    apps = package_uids()
                with store:
                    cycle(store, policy, apps)
                    # Remain idle with an empty registry: avoids a last-off /
                    # concurrent-on race between process exit and lifetime flock.
            except Exception as exc:
                with store:
                    store.state['last_error'] = str(exc)
                    store.save()
                print('UID-network:', str(exc), file=sys.stderr, flush=True)
            ticks += 1
            time.sleep(2)
    finally:
        with store:
            Leases(policy, store.state, store.save).reconcile({})
        # Keep daemon.lock held until process exit; start_daemon serializes here.
        os.close(fd)


def start_daemon(directory):
    # Forking unconditionally is safe: the lifetime flock permits one manager only.
    fd = os.open(directory/'daemon.log', os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        subprocess.Popen([sys.executable, str(Path(__file__).resolve()), 'daemon'],
                         stdin=subprocess.DEVNULL, stdout=fd, stderr=fd, close_fds=True,
                         start_new_session=True, cwd='/')
    finally:
        os.close(fd)


def daemon_running(directory):
    record = load_json(directory/'daemon.json', {})
    try:
        return identity(record['pid']) == record['birth']
    except (OSError, KeyError, IndexError):
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('probe', 'on', 'off', 'attach', 'release', 'status', 'daemon'))
    parser.add_argument('container', nargs='?')
    parser.add_argument('pid', nargs='?', type=int, default=0)
    args = parser.parse_args()
    if fcntl is None or not hasattr(os, 'geteuid'):
        raise Unsupported('UID-network requires Android/Linux')
    if os.geteuid() != 0:
        raise Unsupported('Run through the XTMOE Root helper')
    if args.action == 'daemon':
        daemon()
        return
    if args.action == 'probe':
        policy = Policy()
        print(json.dumps({'supported': True, 'restricted_mode': policy.enabled(), 'scope': 'host UID (shared)'}))
        return
    container = container_path(args.container or '')
    key = hashlib.sha256(str(container).encode()).hexdigest()
    store = Store()
    try:
        policy = Policy()
    except Exception as error:
        if args.action not in ('off', 'release', 'status'):
            raise
        with store:
            if args.action == 'status':
                print(json.dumps({'supported': False, 'error': str(error),
                                  'registered': key in store.state['registrations'],
                                  'manager_running': daemon_running(store.dir)}))
                return
            if args.action == 'off':
                config(container, False)
            pending = unregister_offline(store.state, key)
            store.save()
        if pending:
            raise Unsupported('Registration disabled but owned UID cleanup is pending: ' + ','.join(pending))
        print('UID-network: registration removed; no owned permissions pending; backend unavailable')
        return
    with store:
        if args.action == 'status':
            print(json.dumps({'enabled': (container/'.xtmoe-uid-network').is_file() and
                                         (container/'.xtmoe-uid-network').read_text() == 'enabled=1\n',
                              'registered': key in store.state['registrations'],
                              'manager_running': daemon_running(store.dir),
                              'leases': {u: x for u, x in store.state['leases'].items() if key in x['owners']},
                              'restricted_mode': policy.enabled(), 'last_error': store.state.get('last_error', '')}, sort_keys=True))
            return
        if args.action in ('on', 'attach'):
            record = binding(container, args.pid) if args.pid else None
            if args.action == 'on':
                config(container, True)
            if record:
                store.state['registrations'][key] = record
        else:
            if args.action == 'off':
                config(container, False)
            store.state['registrations'].pop(key, None)
        store.save()
        cycle(store, policy, package_uids())
        needed = bool(store.state['registrations'])
    if needed:
        start_daemon(store.dir)
    print('UID-network: ' + args.action + '; scope=host UID; global restricted mode unchanged')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('UID-network error: ' + str(error), file=sys.stderr)
        sys.exit(1)
