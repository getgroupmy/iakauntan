// Fetches the PDF reader, the first time somebody scans a PDF.
//
// 1.8MB sits behind this, and most people never scan a PDF at all — so
// it is not a script tag that every page load pays for. This file is
// two hundred bytes, loads with the page, and does nothing until asked.
//
// A separate file rather than an inline script because the content
// security policy is `script-src 'self'` with no `unsafe-inline`: an
// inline module would be refused, and refused in a way that looks like
// the reader is missing rather than like the page said no.
//
// Everything is served from this origin. `pdf.js` will otherwise fetch
// its worker from a CDN, which would mean a third party sees every
// document somebody reads.
(function () {
  'use strict';

  var pending = null;

  // Absolute, resolved against the document base. The worker resolves
  // its own URLs against itself, not against the page, so a relative
  // path here goes looking in the wrong place on any route deeper than
  // the root — `/purchases/bill` being the one people actually use.
  function asset(name) {
    return new URL('pdfjs/' + name, document.baseURI).href;
  }

  // Cached, so scanning a second PDF does not fetch it a second time.
  window.loadPdfjs = function () {
    if (pending) return pending;
    pending = import(asset('pdf.js')).then(function (lib) {
      lib.GlobalWorkerOptions.workerSrc = asset('pdf.worker.js');
      return lib;
    }).catch(function (e) {
      // Cleared, so a failure caused by a dropped connection is not
      // remembered for the life of the tab.
      pending = null;
      throw e;
    });
    return pending;
  };
})();
