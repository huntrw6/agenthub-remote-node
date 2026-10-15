// Hermes Remote Helper: STABLE launcher (never changes, so macOS keeps its permissions).
// All behaviour lives in /Library/Application Support/HermesRemote/helper.js, which is
// root-owned; this launcher refuses to load it otherwise.
ObjC.import('Foundation');
var BASE = '/Library/Application Support/HermesRemote';
var LOGF = ObjC.unwrap($.NSHomeDirectory()) + '/Library/Logs/HermesRemote-helper.log';
var impl = null;

function note(m) {
  try {
    var sa = Application.currentApplication();
    sa.includeStandardAdditions = true;
    sa.doShellScript('printf "%s %s\\n" "$(date +%FT%T)" ' + "'" + String(m).replace(/'/g, '') + "' >> '" + LOGF + "'");
  } catch (e) {}
}

function trusted(p) {
  var a = $.NSFileManager.defaultManager.attributesOfItemAtPathError($(p), null);
  var at = ObjC.deepUnwrap(a);
  return !!at && at.NSFileOwnerAccountID === 0 && (at.NSFilePosixPermissions & 18) === 0;
}

function load() {
  var p = BASE + '/helper.js';
  if (!trusted(p) || !trusted(BASE)) { note('helper.js missing or not root-owned: refusing to load'); return; }
  var s = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError($(p), $.NSUTF8StringEncoding, null));
  if (typeof s !== 'string') { note('cannot read helper.js'); return; }
  impl = (new Function(s + '\n;return {tick: tick};'))();
  note('helper loaded');
}

function run() { try { load(); } catch (e) { note('load error: ' + e); } }

function idle() {
  try {
    if (!impl) load();
    if (impl) impl.tick();
  } catch (e) { note('tick error: ' + e); }
  return 1;
}
