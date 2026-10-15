// Hermes Remote Helper logic (JavaScript for Automation). Root-owned; loaded by the stable launcher.
// Runs INSIDE "Hermes Remote Helper.app", so every macOS permission belongs to that one app.
//  1) Permission requests: the installer drops a file in ipc/req/<kind>; we trigger the real macOS
//     prompt, then write ipc/status/<kind> = pending | settings | granted | timeout.
//  2) Signed jobs: AgentHub drops ipc/jobs/<id>.{sig,job}; we verify the signature with the operator
//     key in allowed_signers, run the command as this app (inheriting its permissions), write <id>.out.
ObjC.import('Foundation');
ObjC.import('CoreGraphics');
ObjC.import('ApplicationServices');

// These C functions are NOT exposed automatically in JXA (calling them throws "not a function"),
// so every check silently read as "not granted". They must be bound explicitly.
var BIND = {
  CGPreflightScreenCaptureAccess: ['bool', []],
  CGRequestScreenCaptureAccess: ['bool', []],
  CGPreflightListenEventAccess: ['bool', []],
  CGRequestListenEventAccess: ['bool', []]
};
Object.keys(BIND).forEach(function (n) { try { ObjC.bindFunction(n, BIND[n]); } catch (e) {} });

var VERSION = '6';
var BOOT = Math.floor(Date.now() / 1000);
var BASE = '/Library/Application Support/HermesRemote';
var HOME = ObjC.unwrap($.NSHomeDirectory());
var IPC = HOME + '/Library/Application Support/HermesRemote/ipc';
var LOGF = HOME + '/Library/Logs/HermesRemote-helper.log';
var SA = Application.currentApplication();
SA.includeStandardAdditions = true;
var FM = $.NSFileManager.defaultManager;
var active = {};
var seen = {};
var lastStatus = 0;
var lastDirs = 0;
var JOB_WINDOW = 600; // seconds a signed job stays valid
var JOB_LIMIT = 90;   // seconds a job may run: a command stuck on a macOS prompt must not wedge the helper

function q(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }
function now() { return Math.floor(Date.now() / 1000); }
function can(fn) { try { return !!fn(); } catch (e) { return false; } }
function log(m) { try { SA.doShellScript('printf "%s %s\\n" "$(date +%FT%T)" ' + q(m) + ' >> ' + q(LOGF)); } catch (e) {} }

// shell as this app: returns {rc, out}; children inherit the app's permissions
function sh(cmd) {
  var r;
  try { r = SA.doShellScript('{ ' + cmd + '\n} 2>&1\nprintf "\\n__HR_RC=%s" "$?"'); }
  catch (e) { return { rc: 127, out: String(e) }; }
  var m = /\n?__HR_RC=(\d+)$/.exec(r);
  return { rc: m ? parseInt(m[1], 10) : 127, out: m ? r.slice(0, m.index) : r };
}

function readFile(p) {
  var v = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError($(p), $.NSUTF8StringEncoding, null));
  return typeof v === 'string' ? v : null;
}
function writeFile(p, text) { $(text).writeToFileAtomicallyEncodingError($(p), true, $.NSUTF8StringEncoding, null); }
function listDir(p) {
  var v = ObjC.deepUnwrap(FM.contentsOfDirectoryAtPathError($(p), null));
  return Array.isArray(v) ? v : null;
}
function exists(p) { return !!FM.fileExistsAtPath($(p)); }
function remove(p) { FM.removeItemAtPathError($(p), null); }
function ensureDirs() {
  ['', '/req', '/status', '/jobs'].forEach(function (d) {
    FM.createDirectoryAtPathWithIntermediateDirectoriesAttributesError($(IPC + d), true, $({ NSFilePosixPermissions: 448 }), null);
  });
}

function gateway() {
  var r = sh("/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/gateway:/{print $2}'");
  return r.rc === 0 && r.out.trim() ? r.out.trim() : null;
}

// macOS caches Screen Recording / Input Monitoring answers inside a running process, so a grant is
// invisible until restart. A short-lived child process (attributed to this app by macOS) reads it fresh.
function fresh(expr) {
  var binds = Object.keys(BIND).map(function (n) { return 'ObjC.bindFunction("' + n + '", ' + JSON.stringify(BIND[n]) + ');'; }).join(' ');
  var js = 'ObjC.import("CoreGraphics"); ObjC.import("ApplicationServices"); ' + binds + ' if (!(' + expr + ')) { throw 1; }';
  return sh('/usr/bin/osascript -l JavaScript -e ' + q(js)).rc === 0;
}

// ---- what each permission means and how to test it ----
var CHECK = {
  screen: function () { return can(function () { return $.CGPreflightScreenCaptureAccess(); }) || fresh('$.CGPreflightScreenCaptureAccess()'); },
  accessibility: function () { return can(function () { return $.AXIsProcessTrusted(); }) || fresh('$.AXIsProcessTrusted()'); },
  input: function () { return can(function () { return $.CGPreflightListenEventAccess(); }) || fresh('$.CGPreflightListenEventAccess()'); },
  // A real screen capture. Newer macOS adds a second approval on top of the Screen Recording switch
  // ("bypass the system private window picker", Allow For One Month) that only appears at first capture.
  capture: function () {
    var r = sh("t=$(/usr/bin/mktemp /tmp/hr-cap.XXXXXX); /usr/bin/perl -e 'alarm 20; exec \"/usr/sbin/screencapture\", \"-x\", \"-t\", \"png\", $ARGV[0]' \"$t\" >/dev/null 2>&1; s=$(/usr/bin/stat -f%z \"$t\" 2>/dev/null || echo 0); /bin/rm -f \"$t\"; [ \"$s\" -gt 20000 ]");
    return r.rc === 0;
  },
  // Full Disk Access: TCC.db is unreadable without it
  fda: function () { return sh("/bin/dd if='/Library/Application Support/com.apple.TCC/TCC.db' of=/dev/null bs=1 count=1").rc === 0; },
  // these three raise a real Allow / Don't Allow pop-up by themselves
  // each target app raises its own Allow pop-up the first time; the common ones are asked for now
  // so nothing pops up unexpectedly in the middle of a support session
  automation: function () {
    return ['System Events', 'Finder'].every(function (app) {
      return can(function () { Application(app).name(); return true; });
    });
  },
  // a TCP connect from this app raises the Local Network pop-up; "No route to host" means blocked
  lan: function () {
    var gw = gateway();
    if (!gw) return true;
    var r = sh('/usr/bin/nc -z -G 3 ' + q(gw) + ' 53 2>&1; /usr/bin/nc -z -G 3 ' + q(gw) + ' 80 2>&1');
    return !/No route to host/i.test(r.out);
  },
  files: function () {
    return ['Desktop', 'Documents', 'Downloads'].every(function (d) { return listDir(HOME + '/' + d) !== null; });
  }
};
var PROMPTS = { automation: 1, lan: 1, files: 1, capture: 1 }; // everything else is switched on in Settings
var TRIGGER = {
  screen: function () { $.CGRequestScreenCaptureAccess(); },
  accessibility: function () { $.AXIsProcessTrustedWithOptions($({ AXTrustedCheckOptionPrompt: true })); },
  input: function () { $.CGRequestListenEventAccess(); },
  fda: function () { listDir(HOME + '/Library/Safari'); sh("/bin/ls " + q(HOME + '/Library/Safari') + " >/dev/null"); }
};

function setStatus(id, s) { writeFile(IPC + '/status/' + id, s); }

function stepReq(id) {
  var a = active[id];
  if (a.first) {
    a.first = false;
    setStatus(id, PROMPTS[id] ? 'pending' : 'settings');
    if (TRIGGER[id]) can(TRIGGER[id]);
  }
  if (CHECK[id]()) { setStatus(id, 'granted'); delete active[id]; log(id + ' granted'); return; }
  var age = now() - a.t;
  if (age > 900) { setStatus(id, 'timeout'); delete active[id]; return; }
}

// ---- signed jobs ----
function verified(id) {
  var r = sh('/usr/bin/ssh-keygen -Y verify -f ' + q(BASE + '/allowed_signers') + ' -I hermes -n hermes-remote-job -s ' +
    q(IPC + '/jobs/' + id + '.sig') + ' < ' + q(IPC + '/jobs/' + id + '.job'));
  return r.rc === 0;
}
function b64(s) { return ObjC.unwrap($(s).dataUsingEncoding($.NSUTF8StringEncoding).base64EncodedStringWithOptions(0)); }

function finishJob(id, rc, out) {
  writeFile(IPC + '/jobs/' + id + '.out', JSON.stringify({ rc: rc, out: b64(out) }));
  remove(IPC + '/jobs/' + id + '.job');
  remove(IPC + '/jobs/' + id + '.sig');
}

function processJobs() {
  (listDir(IPC + '/jobs') || []).forEach(function (n) {
    var m = /^([a-f0-9]{16})\.job$/.exec(n);
    if (!m) return;
    var id = m[1];
    if (!exists(IPC + '/jobs/' + id + '.sig')) return; // signature lands first; wait if missing
    if (seen[id]) { remove(IPC + '/jobs/' + id + '.job'); return; }
    seen[id] = 1;
    var job;
    try {
      if (!verified(id)) throw new Error('bad signature');
      job = JSON.parse(readFile(IPC + '/jobs/' + id + '.job'));
      if (job.id !== id || typeof job.cmd !== 'string' || Math.abs(now() - job.ts) > JOB_WINDOW) throw new Error('stale or malformed job');
    } catch (e) {
      log('rejected job ' + id + ': ' + e);
      return finishJob(id, 126, 'rejected: ' + e);
    }
    log('running job ' + id);
    // perl alarm = portable timeout (macOS has no timeout(1)); exit 142 = killed by SIGALRM
    var r = sh('/usr/bin/perl -e ' + q('alarm ' + JOB_LIMIT + '; exec "/bin/sh", "-c", $ARGV[0]') + ' ' + q(job.cmd));
    if (r.rc === 142) r.out += '\n[stopped after ' + JOB_LIMIT + 's: probably waiting on a macOS permission prompt on this Mac]';
    finishJob(id, r.rc, r.out);
  });
}

function writeStatus() {
  lastStatus = now();
  var lines = ['version=' + VERSION, 'boot=' + BOOT, 'ts=' + lastStatus];
  ['screen', 'accessibility', 'input', 'fda'].forEach(function (k) { lines.push(k + '=' + (CHECK[k]() ? 1 : 0)); });
  writeFile(IPC + '/status.txt', lines.join('\n') + '\n');
}

function tick() {
  if (now() - lastDirs > 60) { ensureDirs(); lastDirs = now(); }
  (listDir(IPC + '/req') || []).forEach(function (n) {
    if (CHECK.hasOwnProperty(n)) { remove(IPC + '/req/' + n); active[n] = { t: now(), first: true }; }
  });
  Object.keys(active).forEach(stepReq);
  processJobs();
  if (now() - lastStatus >= 20) writeStatus();
}
