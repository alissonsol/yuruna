// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
//
// What the download-agent UI adds to the shared runtime: the control-proof
// exchange its gated controls wait on. Everything page-agnostic -- Y.el, Y.api,
// the chrome, the table furniture, the byte and duration formatting -- comes
// from /assets/yuruna.core.js, which every page loads first.
//
// ES5 ONLY. See the header of yuruna.core.js for why, and run
// tools/Invoke-Es5Check.ps1 before shipping a change here.
(function (window) {
  'use strict';

  var Y = window.Y;

  // Started at load so the gate is already open by the time a page reads it.
  // Arriving through a link on the Yuruna hosts dashboard is then enough to use
  // Force refresh, Delete and Prune -- the operator is not sent back to the
  // dashboard to copy the rotating code off a tile.
  //
  // Taken raw, not decodeURIComponent'd: the proof is
  // "<digits>.<standard base64>", which has nothing to decode, and a stray %
  // would only make it throw.
  Y.startProofUnlock({ decode: false });
}(window));
