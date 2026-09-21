// The Turnstile challenge for the phone apps. Loaded by captcha.html.
//
// A FILE rather than an inline <script> because the deployed policy is
//
//   script-src 'self' 'wasm-unsafe-eval' https://challenges.cloudflare.com
//
// and an inline block is refused by it -- silently, in the browser,
// which on a sign-in screen looks like a challenge that never loads.
// `scripts/check_inline_scripts.py` refuses it here instead, and says
// in its own header what hashing the script instead cost last time:
// the hash is of exact bytes, so the next edit re-breaks it with no
// visible symptom.
//
// `lib/src/features/auth/captcha_native.dart` is the other half of the
// contract below -- the `Captcha` channel, and the three message kinds.
// Everything this page reports goes through one function, so there
// is a single place where the contract with the app is written
// down. `Captcha` is the JavaScript channel the webview installs;
// it is absent when this page is opened in an ordinary browser,
// which is a thing that happens by accident and must not throw.
function send(kind, value) {
  try {
    if (window.Captcha && window.Captcha.postMessage) {
      window.Captcha.postMessage(JSON.stringify({ kind: kind, value: value || '' }));
    }
  } catch (e) {
    // Nothing useful to do: the channel is how we would report it.
  }
}

function fail(why) {
  document.getElementById('box').style.display = 'none';
  document.getElementById('failed').style.display = 'block';
  send('failed', why);
}

var key = new URLSearchParams(location.search).get('k') || '';
if (!key) {
  fail('no site key');
}

// `onloadTurnstileCallback` is the name the script's `onload`
// parameter below asks for. Turnstile calls it once its own script
// is ready, which is the only moment `turnstile.render` is safe.
window.onloadTurnstileCallback = function () {
  if (!key) return;
  try {
    turnstile.render('#box', {
      sitekey: key,
      callback: function (token) { send('token', token); },
      // A token is good for five minutes. The app is told it went
      // rather than being left holding one GoTrue will refuse,
      // which is a refusal with nothing on screen to explain it.
      'expired-callback': function () { send('expired', ''); },
      'timeout-callback': function () { send('expired', ''); },
      'error-callback': function () { fail('challenge error'); return true; },
      theme: new URLSearchParams(location.search).get('theme') === 'dark'
        ? 'dark' : 'light',
    });
  } catch (e) {
    fail('render threw');
  }
};

// If the script itself cannot be fetched -- a blocked network, a
// captive portal, an offline phone -- nothing above ever runs, and
// the app would wait forever on a blank box. So the failure is
// reported from the tag's own onerror.
var s = document.createElement('script');
s.src = 'https://challenges.cloudflare.com/turnstile/v0/api.js'
      + '?onload=onloadTurnstileCallback&render=explicit';
s.async = true;
s.defer = true;
s.onerror = function () { fail('script blocked'); };
document.head.appendChild(s);
