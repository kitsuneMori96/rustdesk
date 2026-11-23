import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../common/shared_state.dart';
import '../../common/widgets/dialog.dart';
import '../../consts.dart';
import '../../models/platform_model.dart';
import '../../models/uu_state.dart';
import '../auto_unlock_config.dart';
import '../dpi_adapt.dart';
import 'remote_page.dart';

const String _kPrivacyVdImpl = 'privacy_mode_impl_virtual_display';

class UuChrome extends StatefulWidget {
  final String id;
  final VoidCallback onToggleGestureHelp;
  final VoidCallback onShowActions;

  const UuChrome(
      {Key? key,
      required this.id,
      required this.onToggleGestureHelp,
      required this.onShowActions})
      : super(key: key);

  @override
  State<UuChrome> createState() => _UuChromeState();
}

class _UuChromeState extends State<UuChrome> with WidgetsBindingObserver {
  static const _imageQualityLabels = {
    kRemoteImageQualityBest: '清晰',
    kRemoteImageQualityBalanced: '平衡',
    kRemoteImageQualityLow: '流畅',
    kRemoteImageQualityCustom: '自定义',
  };

  Timer? _hideTimer;
  Timer? _fadeTimer;
  Timer? _privacyStartTimer;
  Timer? _privacyRetryTimer;
  Timer? _privacyFailTimer;
  Timer? _privacyProbeTimer;
  Timer? _privacyAwaitTimer;
  Timer? _privacyHostFailTimer;
  Timer? _mutePendingTimer;
  bool? _privacyPendingOn;
  bool _privacyPreplugged = false;
  // The ON request is gated on the host being unlocked: while the host sits at
  // the lock screen Windows rejects the display commit, so we wait for the
  // unlock instead of letting the fail timer flip the switch off.
  bool _privacyAwaitUnlock = false;
  bool _privacyCommitted = false;
  bool _privacyAuto = false;
  int _privacyProbeRetries = 0;
  // A lock transition can still look unlocked for a moment. Confirming the
  // state 0 reply once more ~600 ms later keeps a mid-lock commit from being
  // sent (the host would fail it and surface an error).
  bool _privacyZeroSeen = false;
  int _privacyHostFails = 0;
  // True while auto-recovering privacy after reconnect: a display commit
  // rejected at the lock screen must not flip the switch off, so the tile
  // keeps showing on until the host is unlocked and privacy commits.
  bool _privacyAutoRecovering = false;
  bool _mutePending = false;
  Worker? _privacyWorker;
  Worker? _railWorker;
  Worker? _hostStateWorker;
  Worker? _peerReadyWorker;
  Worker? _lockWorker;
  Worker? _unlockWorker;
  Worker? _privacyFailWorker;
  bool _faded = false;
  final Set<String> _expanded = {};
  String? _imageQuality;
  bool _imageQualityLoaded = false;

  // Unique collapse key for the "其他设置" expansion inside the operation
  // card, so it never collides with a _groupCard title sharing _expanded.
  static const String _kKeymapMoreKey = 'op-keymap-more';

  // Diagnostic trace for the privacy state machine: sessions can be rebuilt
  // while a restore is in flight, so every line carries the instance id and
  // the live session id to tell which chrome acted.
  void _diag(String msg) =>
      debugPrint('[uu-diag] chrome#$hashCode sid=${gFFI.sessionId} $msg');

  String get _privacyFlags =>
      'pending=$_privacyPendingOn await=$_privacyAwaitUnlock commit=$_privacyCommitted '
      'zero=$_privacyZeroSeen fails=$_privacyHostFails retries=$_privacyProbeRetries auto=$_privacyAuto';

  @override
  void initState() {
    super.initState();
    _diag('init peer=${widget.id} intent=${_hostIntent('privacy')}');
    _railWorker = ever(uuState.railOpen, (bool open) {
      _hideTimer?.cancel();
      if (open) {
        _hideTimer = Timer(const Duration(seconds: 6), () {
          uuState.railOpen.value = false;
        });
      } else {
        _poke();
      }
    });
    _loadImageQuality();
    _privacyWorker = ever(PrivacyModeState.find(widget.id), (String state) {
      _diag('PrivacyModeState "$state" $_privacyFlags');
      if (!mounted || _privacyPendingOn == null) return;
      if (state.isEmpty && _privacyPendingOn == true) {
        // A rejected ON echoes an empty impl key before/around the failure
        // event. Keep the pending flow alive so the failure handler can
        // re-probe the lock state and retry once the host unlocks; clearing
        // here used to kill the retry and surface a toast immediately.
        _diag('empty echo while pending ON -> keep flow');
        return;
      }
      _privacyStartTimer?.cancel();
      _privacyRetryTimer?.cancel();
      _privacyFailTimer?.cancel();
      _privacyProbeTimer?.cancel();
      _privacyAwaitTimer?.cancel();
      _privacyHostFailTimer?.cancel();
      if (state.isNotEmpty) _privacyAutoRecovering = false;
      setState(() {
        _privacyPendingOn = null;
        _privacyAwaitUnlock = false;
        _privacyCommitted = false;
        _privacyZeroSeen = false;
        _privacyHostFails = 0;
      });
    });
    _restorePrivacyIntent();
    _poke();
    WidgetsBinding.instance.addObserver(this);
    _hostStateWorker = ever(uuState.hostStateVersion, (_) {
      if (mounted) setState(() {});
    });
    _lockWorker = ever(uuState.hostLockState, (int? s) => _onLockState(s));
    _unlockWorker =
        ever(uuState.hostUnlockState, (String? st) => _onUnlockState(st));
    uuState.chromeMounted();
    _privacyFailWorker = ever(
        uuState.privacyFailureSeq, (_) => _onPrivacyHostFailure());
    _peerReadyWorker = ever(gFFI.ffiModel.pi.isSet, (bool set) {
      if (set) {
        _queryHostMute();
        _applyAdaptiveDisplay();
      }
    });
    if (gFFI.ffiModel.pi.isSet.value) _queryHostMute();
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyAdaptiveDisplay());
  }

  // First-connect default for the virtual display: match the phone's own
  // physical resolution. An explicit choice in the picker always wins.
  void _applyAdaptiveDisplay() {
    if (!mounted || !_hostControlSupported) return;
    if (_hostSetting('display', '').isNotEmpty) return;
    final mode = adaptiveDisplayMode(context);
    if (mode == null) return;
    _setHostSetting('display', mode);
    final (w, h) = _parseDisplayMode(mode);
    _sendHostCmd('display:${w}x$h', true);
  }

  // Pull the host's real mute state on connect and on foreground resume; the
  // user may have toggled Windows mute directly while the app was away.
  void _queryHostMute() {
    if (!mounted || !_hostControlSupported) return;
    _sendHostCmd('mute?', true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _queryHostMute();
  }

  // Physical screen-off is an explicit per-peer choice; the host restores
  // the screen on every disconnect, so re-apply it on reconnect. Window
  // display commits are rejected while the host sits at the lock screen, so
  // keep retrying until the session is back and the intent still stands.
  void _restorePrivacyIntent() {
    if (!_hostIntent('privacy')) return;
    _diag('restore start');
    _privacyAutoRecovering = true;
    // Time budget rather than a try count: the host may sit at the lock screen
    // for ~25 s before auto-unlock lands, and the 2 s/4 s chains burned a fixed
    // 20-try budget long before then.
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    var tries = 0;
    void attempt() {
      if (!mounted) return;
      if (!_hostIntent('privacy') ||
          PrivacyModeState.find(widget.id).value.isNotEmpty) {
        _diag('restore stop: intent=${_hostIntent('privacy')} '
            'state="${PrivacyModeState.find(widget.id).value}" $_privacyFlags');
        _privacyAutoRecovering = false;
        return;
      }
      if (DateTime.now().isAfter(deadline)) {
        _diag('restore deadline hit $_privacyFlags');
        _privacyAutoRecovering = false;
        setState(() => _privacyPendingOn = null);
        return;
      }
      if (_privacyPendingOn != null) {
        _diag('restore try#$tries wait (pending non-null) $_privacyFlags');
        Timer(const Duration(seconds: 2), attempt);
        return;
      }
      if (_privacySupported()) {
        _diag('restore try#$tries -> toggle ON '
            'state="${PrivacyModeState.find(widget.id).value}" $_privacyFlags');
        _togglePrivacy(true, auto: true);
        Timer(const Duration(seconds: 4), attempt);
        return;
      }
      // Peer info can arrive a few seconds after the page is built.
      _diag('restore try#$tries unsupported yet');
      tries++;
      Timer(Duration(milliseconds: tries < 10 ? 800 : 3000), attempt);
    }

    Future.delayed(const Duration(milliseconds: 600), attempt);
  }

  @override
  void dispose() {
    _diag('dispose $_privacyFlags');
    _hideTimer?.cancel();
    _fadeTimer?.cancel();
    _privacyStartTimer?.cancel();
    _privacyRetryTimer?.cancel();
    _privacyFailTimer?.cancel();
    _privacyProbeTimer?.cancel();
    _privacyAwaitTimer?.cancel();
    _mutePendingTimer?.cancel();
    _privacyWorker?.dispose();
    _railWorker?.dispose();
    _hostStateWorker?.dispose();
    _peerReadyWorker?.dispose();
    _lockWorker?.dispose();
    _unlockWorker?.dispose();
    _privacyFailWorker?.dispose();
    _privacyHostFailTimer?.cancel();
    uuState.chromeDisposed();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _loadImageQuality() async {
    String? quality;
    try {
      quality = await bind.sessionGetImageQuality(sessionId: gFFI.sessionId);
    } catch (_) {
      quality = null;
    }
    if (!mounted) return;
    setState(() {
      _imageQuality = quality;
      _imageQualityLoaded = true;
    });
  }

  // Idle edge button fades out after a few seconds without interaction.
  void _poke() {
    _fadeTimer?.cancel();
    if (_faded) setState(() => _faded = false);
    _fadeTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _faded = true);
    });
  }

  // The remote page permanently holds FLAG_ALT_FOCUSABLE_IM so its hidden
  // TextField can control the IME; that flag also suppresses the system
  // keyboard for dialogs, so lift it only while an input dialog is up.
  Future<T?> _withIme<T>(Future<T?> Function() run) async {
    await gFFI.invokeMethod("enable_soft_keyboard", true);
    try {
      return await run();
    } finally {
      if (mounted) gFFI.invokeMethod("enable_soft_keyboard", false);
    }
  }

  bool get _hostControlSupported =>
      gFFI.ffiModel.pi.platformAdditions.containsKey(
          kPlatformAdditionsUuHostControl);

  // Reuses the privacy-mode message as a command channel: the host side of
  // this fork treats impl keys prefixed with "uu:" as host controls.
  void _sendHostCmd(String cmd, bool on) {
    bind.sessionTogglePrivacyMode(
        sessionId: gFFI.sessionId, implKey: 'uu:$cmd', on: on);
  }

  String _hostIntentKey(String name) => uuHostIntentKey(name, widget.id);

  bool _hostIntent(String name, {bool fallback = false}) {
    final raw = bind.mainGetLocalOption(key: _hostIntentKey(name));
    return raw.isEmpty ? fallback : raw == '1';
  }

  void _setHostIntent(String name, bool on) {
    bind.mainSetLocalOption(key: _hostIntentKey(name), value: on ? '1' : '0');
  }

  String _hostSetting(String name, String fallback) {
    final raw = bind.mainGetLocalOption(key: _hostIntentKey(name));
    return raw.isEmpty ? fallback : raw;
  }

  void _setHostSetting(String name, String value) {
    bind.mainSetLocalOption(key: _hostIntentKey(name), value: value);
  }

  (int, int) _parseDisplayMode(String mode) {
    final parts = mode.split('x');
    if (parts.length == 2) {
      return (int.tryParse(parts[0]) ?? 1920, int.tryParse(parts[1]) ?? 1080);
    }
    return (1920, 1080);
  }

  void _toggleMute(bool on) {
    _mutePendingTimer?.cancel();
    setState(() {
      _mutePending = true;
      _setHostIntent('mute', on);
    });
    _sendHostCmd('mute', on);
    // No ack frame for host controls; give the host a beat, then settle.
    _mutePendingTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _mutePending = false);
    });
  }

  bool _privacySupported() {
    final impls = gFFI.ffiModel.pi.platformAdditions[
        kPlatformAdditionsSupportedPrivacyModeImpl] as List?;
    return impls != null &&
        impls.any(
            (e) => (e as List).isNotEmpty && e[0] == _kPrivacyVdImpl);
  }

  // `on` is the user's intent, persisted per peer: the host always restores
  // the physical screen on disconnect, so a new session re-applies it.
  void _togglePrivacy(bool next, {bool auto = false}) {
    final cur = PrivacyModeState.find(widget.id).value.isNotEmpty;
    _diag('toggle next=$next auto=$auto curState=$cur $_privacyFlags');
    // A pending ON can still be canceled (turning OFF); ignore redundant
    // same-state taps otherwise.
    if (_privacyPendingOn != null && !(_privacyPendingOn == true && !next)) {
      _diag('toggle ignored (pending in flight)');
      return;
    }
    if (cur == next) {
      _diag('toggle ignored (already $next)');
      return;
    }
    if (!_privacySupported()) {
      if (!auto) showToast('被控端不支持虚拟屏防窥（需安装版+服务运行）');
      return;
    }
    if (next && gFFI.ffiModel.permissions['privacy_mode'] == false) {
      if (!auto) showToast('被控端未授权防窥模式');
      return;
    }
    setState(() => _privacyPendingOn = next);
    _setHostIntent('privacy', next);
    _privacyStartTimer?.cancel();
    _privacyRetryTimer?.cancel();
    _privacyFailTimer?.cancel();
    if (!next) {
      _privacyProbeTimer?.cancel();
      _privacyAwaitTimer?.cancel();
      _privacyHostFailTimer?.cancel();
      _privacyAwaitUnlock = false;
      _privacyCommitted = false;
      _privacyZeroSeen = false;
      _privacyHostFails = 0;
      bind.sessionTogglePrivacyMode(
          sessionId: gFFI.sessionId, implKey: _kPrivacyVdImpl, on: false);
      _privacyFailTimer = Timer(const Duration(seconds: 6), () {
        if (!mounted || _privacyPendingOn != false) return;
        if (PrivacyModeState.find(widget.id).value.isNotEmpty) {
          setState(() => _privacyPendingOn = null);
          showToast('关闭防窥未响应，请稍后重试');
        }
      });
      return;
    }
    _privacyProbeTimer?.cancel();
    _privacyAwaitTimer?.cancel();
    _privacyHostFailTimer?.cancel();
    _privacyAwaitUnlock = false;
    _privacyCommitted = false;
    _privacyAuto = auto;
    _privacyProbeRetries = 0;
    _privacyZeroSeen = false;
    _privacyHostFails = 0;
    // ON must not race the lock screen: first ask the host whether it is
    // unlocked, then commit the physical screen-off only once state==0 (a
    // confirmed unlocked desktop). Retry the probe a couple of times before
    // assuming an old host, so a single dropped reply can't make us commit
    // (and fail) while the host is actually at the lock screen.
    uuState.hostLockState.value = null;
    uuState.hostUnlockState.value = null;
    _beginPrivacyProbe();
  }

  void _beginPrivacyProbe() {
    if (!mounted || _privacyPendingOn != true || _privacyCommitted) return;
    _diag('probe send retries=$_privacyProbeRetries');
    _sendHostCmd('lock?', true);
    _privacyProbeTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || _privacyPendingOn != true || _privacyCommitted) return;
      if (uuState.hostLockState.value != null) return; // reply handled it
      _diag('probe timeout retries=$_privacyProbeRetries '
          'hostControl=$_hostControlSupported');
      _privacyProbeRetries++;
      if (_privacyProbeRetries < 3) {
        // Reset so an identical reply (e.g. 0 again) still notifies.
        uuState.hostLockState.value = null;
        _beginPrivacyProbe();
      } else if (_hostControlSupported) {
        // The reverse channel exists but never answered. Committing blind is
        // exactly how a lock-screen commit failure happens, so give up here.
        _diag('probe give up (host control unanswered)');
        _setHostIntent('privacy', false);
        setState(() {
          _privacyCommitted = false;
          _privacyAwaitUnlock = false;
          _privacyPendingOn = null;
        });
        if (!_privacyAuto) {
          showToast('无法确认电脑是否已解锁，防窥已取消；解锁后再试');
        }
      } else {
        // Old host with no `lock?` reply: legacy direct commit.
        _diag('probe give up -> legacy commit');
        _commitPrivacyOn();
      }
    });
  }

  void _onLockState(int? s) {
    if (_privacyPendingOn != true || _privacyCommitted) {
      return;
    }
    if (s == null) return; // probe retry handles the no-reply case
    _diag('lock-state reply s=$s $_privacyFlags');
    _privacyProbeTimer?.cancel();
    if (s == 0) {
      if (!_privacyZeroSeen) {
        // A lock transition can still read as the normal desktop for a moment.
        // Confirm once more after a short settle before committing, otherwise
        // the host gets the request just as Windows locks and rejects it.
        _diag('lock-state 0 first sample -> confirm in 600ms');
        _privacyZeroSeen = true;
        uuState.hostLockState.value = null;
        _privacyProbeTimer =
            Timer(const Duration(milliseconds: 600), _beginPrivacyProbe);
        return;
      }
      _diag('lock-state 0 confirmed -> commit');
      _privacyAwaitUnlock = false;
      _commitPrivacyOn();
      return;
    }
    _privacyZeroSeen = false;
    // 2 = lock screen, 1 = Winlogon/secure desktop/transition, -1 = could not
    // read the input desktop. All mean "not a confirmed unlocked desktop", and
    // Windows rejects display commits in these states, so wait and re-probe
    // instead of committing (which would fail and flip the switch off).
    if (_privacyAwaitUnlock) return; // already watching; poll timer decides
    _diag('lock-state $s -> wait for unlock');
    setState(() => _privacyAwaitUnlock = true);
    _privacyPreplugged = false;
    if (s == 2) _triggerAutoUnlockIfNeeded();
    _startUnlockWatch();
  }

  // While the host is not on a confirmed unlocked desktop, re-probe every 4 s
  // so we commit the instant it unlocks, and never give up merely because the
  // host stayed locked — the switch keeps showing ON ("等待解锁") meanwhile.
  void _startUnlockWatch() {
    _privacyAwaitTimer?.cancel();
    final deadline = DateTime.now().add(const Duration(minutes: 10));
    void tick() {
      if (!mounted || _privacyPendingOn != true || _privacyCommitted) return;
      if (DateTime.now().isAfter(deadline)) {
        _privacyAwaitTimer?.cancel();
        _setHostIntent('privacy', false);
        setState(() {
          _privacyAwaitUnlock = false;
          _privacyPendingOn = null;
        });
        if (!_privacyAuto) {
          showToast('电脑长时间锁屏，防窥未开启；解锁后请重新开启');
        }
        return;
      }
      _diag('await watch tick $_privacyFlags');
      _sendHostCmd('lock?', true);
      _privacyAwaitTimer = Timer(const Duration(seconds: 4), tick);
    }

    _privacyAwaitTimer = Timer(const Duration(seconds: 4), tick);
  }

  void _onUnlockState(String? st) {
    _diag('unlock-state reply "$st" $_privacyFlags');
    if (_privacyPendingOn != true || !_privacyAwaitUnlock || _privacyCommitted) {
      return;
    }
    if (st == 'success' || st == 'skipped') {
      _privacyAwaitTimer?.cancel();
      setState(() => _privacyAwaitUnlock = false);
      _commitPrivacyOn();
    }
    // 'failed': keep waiting; the user may unlock by hand. The unlock watch
    // keeps re-probing until it commits or hits its deadline.
  }

  // Host-reported privacy failure. Most often the display commit landed right
  // as Windows locked, so re-probe instead of flipping the switch off: if the
  // host is not on a confirmed unlocked desktop, fall back to waiting.
  void _onPrivacyHostFailure() {
    if (!mounted) return;
    final msg = uuState.privacyFailureText.value;
    _diag('host failure "$msg" $_privacyFlags mounted=$mounted');
    if (_privacyPendingOn != true) {
      // The official .so re-applies the persisted privacy option on the first
      // frame of every reconnect, bypassing our lock probe. If the host was
      // locked, the commit fails; recover through the gated flow instead of
      // surfacing an error, as long as the user still wants privacy on.
      if (_hostIntent('privacy')) {
        _diag('host failure without pending -> recover via lock probe');
        _privacyStartTimer?.cancel();
        _privacyRetryTimer?.cancel();
        _privacyFailTimer?.cancel();
        _privacyProbeTimer?.cancel();
        _privacyAwaitTimer?.cancel();
        _privacyHostFailTimer?.cancel();
        setState(() {
          _privacyPendingOn = true;
          _privacyAwaitUnlock = false;
          _privacyCommitted = false;
          _privacyZeroSeen = false;
        });
        _privacyAuto = true;
        _privacyAutoRecovering = true;
        _privacyPreplugged = false;
        _privacyProbeRetries = 0;
        _privacyHostFails = 0;
        uuState.hostLockState.value = null;
        uuState.hostUnlockState.value = null;
        _beginPrivacyProbe();
        return;
      }
      // No pending flow and no stored intent: nothing to recover, and the
      // host's raw error is noise (it also fires on every reconnect attempt).
      _diag('failure ignored (no pending, intent off)');
      return;
    }
    _privacyStartTimer?.cancel();
    _privacyRetryTimer?.cancel();
    _privacyFailTimer?.cancel();
    _privacyProbeTimer?.cancel();
    _privacyAwaitTimer?.cancel();
    _privacyHostFailTimer?.cancel();
    _privacyCommitted = false;
    _privacyPreplugged = false;
    _privacyZeroSeen = false;
    // Drop the waiting flag so the re-probe can arm the unlock watch again.
    if (_privacyAwaitUnlock) setState(() => _privacyAwaitUnlock = false);
    _privacyHostFails++;
    _diag('failure re-probe in 800ms fails=$_privacyHostFails');
    if (_privacyHostFails > 2) {
      _diag('failure give up after $_privacyHostFails');
      _setHostIntent('privacy', false);
      _privacyAutoRecovering = false;
      setState(() {
        _privacyAwaitUnlock = false;
        _privacyPendingOn = null;
      });
      if (!_privacyAuto) {
        showToast('防窥未能开启，请解锁电脑后再试');
      }
      return;
    }
    _privacyHostFailTimer = Timer(const Duration(milliseconds: 800), () {
      if (!mounted || _privacyPendingOn != true) return;
      uuState.hostLockState.value = null;
      _beginPrivacyProbe();
    });
  }

  // Re-send the auto-unlock command so the host can leave the lock screen,
  // mirroring remote_page's first-frame path. No-op when not configured or the
  // host lacks the capability.
  Future<void> _triggerAutoUnlockIfNeeded() async {
    final sid = gFFI.sessionId;
    final cfg = AutoUnlockConfig.load(widget.id);
    if (cfg['on'] != true) {
      _diag('auto-unlock skipped (not configured)');
      return;
    }
    final additions = gFFI.ffiModel.pi.platformAdditions;
    if (additions['uu_auto_unlock'] != true) {
      _diag('auto-unlock skipped (host lacks capability)');
      return;
    }
    final pwd = await AutoUnlockConfig.password(cfg);
    if (pwd == null || pwd.isEmpty || !mounted || gFFI.sessionId != sid) {
      _diag('auto-unlock skipped (no password / session changed)');
      return;
    }
    _diag('auto-unlock request sent');
    bind.sessionTogglePrivacyMode(
        sessionId: sid,
        implKey: 'uu:unlock:${base64Encode(utf8.encode(pwd))}',
        on: true);
  }

  void _commitPrivacyOn() {
    if (!mounted || _privacyPendingOn != true) return;
    _diag('commit ON preplugged=$_privacyPreplugged '
        'isAmyuni=${gFFI.ffiModel.pi.isAmyuniIdd} '
        'vd=${gFFI.ffiModel.pi.RustDeskVirtualDisplays.length} '
        'amyuni=${gFFI.ffiModel.pi.amyuniVirtualDisplayCount} $_privacyFlags');
    _privacyCommitted = true;
    _privacyProbeTimer?.cancel();
    _privacyAwaitTimer?.cancel();
    _privacyHostFailTimer?.cancel();
    _privacyAwaitUnlock = false;
    _privacyZeroSeen = false;
    // turn_on only waits 5s for the virtual display to appear, but Amyuni's
    // monitor needs ~6s to reach ACTIVE. Plug it first so the server-side
    // check finds it instead of racing.
    final auto = _privacyAuto;
    final preplug = gFFI.ffiModel.pi.isAmyuniIdd;
    final hadVirtualDisplay =
        gFFI.ffiModel.pi.RustDeskVirtualDisplays.isNotEmpty ||
            gFFI.ffiModel.pi.amyuniVirtualDisplayCount > 0;
    void requestPrivacy() {
      if (!mounted || _privacyPendingOn != true) return;
      debugPrint(
          '[uu-diag] requestPrivacy ON impl=$_kPrivacyVdImpl preplug=$preplug hadVD=$hadVirtualDisplay');
      bind.sessionTogglePrivacyMode(
          sessionId: gFFI.sessionId, implKey: _kPrivacyVdImpl, on: true);
    }

    if (preplug && !hadVirtualDisplay && !_privacyPreplugged) {
      _diag('commit preplug virtual display, poll until ready (max 4s)');
      _privacyPreplugged = true;
      bind.sessionToggleVirtualDisplay(
          sessionId: gFFI.sessionId, index: 0, on: true);
      // Amyuni's monitor needs a moment to reach ACTIVE; commit as soon as it
      // shows up plus a short settle instead of always burning 4 s.
      final begin = DateTime.now();
      DateTime? activeSince;
      _privacyStartTimer =
          Timer.periodic(const Duration(milliseconds: 250), (t) {
        if (!mounted || _privacyPendingOn != true) {
          t.cancel();
          return;
        }
        final now = DateTime.now();
        if (gFFI.ffiModel.pi.RustDeskVirtualDisplays.isNotEmpty ||
            gFFI.ffiModel.pi.amyuniVirtualDisplayCount > 0) {
          activeSince ??= now;
        }
        final ready = activeSince != null &&
            now.difference(activeSince!).inMilliseconds >= 1200;
        final timedOut = now.difference(begin).inSeconds >= 4;
        if (ready || timedOut) {
          t.cancel();
          _diag('preplug ready=$ready after '
              '${now.difference(begin).inMilliseconds}ms');
          requestPrivacy();
        }
      });
    } else {
      requestPrivacy();
    }
    _privacyRetryTimer = Timer(const Duration(seconds: 12), () {
      if (!mounted || _privacyPendingOn != true) return;
      if (PrivacyModeState.find(widget.id).value.isEmpty) {
        _diag('12s retry -> requestPrivacy again');
        requestPrivacy();
      }
    });
    // Only armed now that the host is confirmed unlocked, so a lock-screen
    // rejection can no longer flip the switch off mid-wait.
    _privacyFailTimer = Timer(Duration(seconds: auto ? 8 : 20), () {
      if (!mounted || _privacyPendingOn != true) return;
      _diag('fail timer fired state="${PrivacyModeState.find(widget.id).value}" '
          '(auto=$auto)');
      if (PrivacyModeState.find(widget.id).value.isEmpty) {
        debugPrint(
            '[uu-diag] privacy ON fail-timer fired, state still empty (auto=$auto)');
        setState(() {
          _privacyCommitted = false;
          _privacyPendingOn = null;
        });
        if (auto) {
          // A commit rejected at the lock screen may leave the virtual display
          // unplugged; allow the next round to pre-plug again. Keep the intent
          // and the switch on (_privacyAutoRecovering) until the host unlocks.
          _privacyPreplugged = false;
        } else if (preplug && !hadVirtualDisplay) {
          bind.sessionToggleVirtualDisplay(
              sessionId: gFFI.sessionId, index: 0, on: false);
          _privacyPreplugged = false;
          showToast('开启失败：被控端未找到虚拟显示器，驱动刚装好时请重启电脑再试');
        }
      }
    });
  }

  void _sendWinCombo(String key) {
    final input = gFFI.inputModel;
    final oldCommand = input.command;
    input.command = true;
    input.inputKey(key);
    input.command = oldCommand;
  }

  void _openKeyboard() {
    uuState.railOpen.value = false;
    uuState.drawerPage.value = null;
    uuState.keyboardOpen.value = true;
  }

  void _openDrawer(String page) {
    uuState.railOpen.value = false;
    uuState.drawerPage.value = page;
    if (page == 'menu') {
      _loadImageQuality();
    }
  }

  void _setImageQuality(String value) {
    setState(() => _imageQuality = value);
    unawaited(
        bind.sessionSetImageQuality(sessionId: gFFI.sessionId, value: value));
    if (value == kRemoteImageQualityCustom) {
      uuState.drawerPage.value = null;
      customImageQualityDialog(gFFI.sessionId, widget.id, gFFI);
    }
  }

  Future<void> _showQualityPicker() async {
    if (!_imageQualityLoaded) await _loadImageQuality();
    if (!mounted) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('画面质量'),
        children: _imageQualityLabels.entries
            .map((e) => SimpleDialogOption(
                  onPressed: () => Navigator.of(ctx).pop(e.key),
                  child: Text(
                      '${e.value}${_imageQuality == e.key ? '  ✓' : ''}'),
                ))
            .toList(),
      ),
    );
    if (picked == null || !mounted) return;
    _setImageQuality(picked);
  }

  Widget _imageQualitySection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('画面质量',
              style: TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final entry in _imageQualityLabels.entries)
                ChoiceChip(
                  label: Text(entry.value,
                      style: TextStyle(
                          color: _imageQuality == entry.key
                              ? Colors.black
                              : Colors.white,
                          fontSize: 12)),
                  selected: _imageQuality == entry.key,
                  showCheckmark: false,
                  selectedColor: MyTheme.accent,
                  backgroundColor: const Color(0xFF3A3A3C),
                  side: BorderSide.none,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => _setImageQuality(entry.key),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _railItem(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 26),
            const SizedBox(height: 6),
            Text(label,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _edgeButton(Size size) {
    final px =
        (uuState.railX * size.width).clamp(0.0, size.width - 56).toDouble();
    final py =
        (uuState.railY * size.height).clamp(0.0, size.height - 56).toDouble();
    return Positioned(
      left: px,
      top: py,
      child: GestureDetector(
        onTap: () {
          _poke();
          _openDrawer('menu');
        },
        onPanStart: (_) => _poke(),
        onPanUpdate: (d) {
          setState(() {
            final nx =
                (px + d.delta.dx).clamp(0.0, size.width - 56).toDouble();
            final ny =
                (py + d.delta.dy).clamp(0.0, size.height - 56).toDouble();
            uuState.railX = nx / size.width;
            uuState.railY = ny / size.height;
          });
        },
        onPanEnd: (_) {
          uuState.save();
          _poke();
        },
        child: AnimatedOpacity(
          opacity: _faded ? 0.15 : 0.55,
          duration: const Duration(milliseconds: 600),
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withOpacity(0.55),
            ),
            child: const Icon(Icons.tune, color: Colors.white, size: 22),
          ),
        ),
      ),
    );
  }

  // UU-style right-edge icon rail: no background panel, four items spread over
  // the full right edge. Tap-outside to dismiss is owned by the drawer/keyboard
  // barriers, so this column itself adds no full-screen gesture layer and can
  // sit on top of the open drawer.
  Widget _railColumn() {
    final isPeerAndroid = gFFI.ffiModel.isPeerAndroid;
    return Positioned(
      top: 0,
      bottom: 0,
      right: 0,
      width: 72,
      child: Column(
        children: [
          // Each item owns a full quarter of the right edge, not just
          // the small icon area.
          Expanded(
              child: _railItem(Icons.tune, '操作', () {
            // Toggle: a second tap on 操作 collapses whatever is open back to
            // the minimized tool ball instead of doing nothing.
            if (uuState.drawerPage.value != null) {
              uuState.drawerPage.value = null;
            } else if (uuState.railOpen.value) {
              uuState.railOpen.value = false;
            } else {
              _openDrawer('menu');
            }
          })),
          Expanded(child: _railItem(Icons.keyboard, '键盘', _openKeyboard)),
          Expanded(
              child: _railItem(
                  Icons.desktop_windows, '显示桌面', () => _sendWinCombo('VK_D'))),
          Expanded(
            child: _railItem(
                isPeerAndroid ? Icons.build : Icons.grid_view,
                isPeerAndroid ? '更多操作' : '所有窗口',
                () => isPeerAndroid
                    ? gFFI.dialogManager.toggleMobileActionsOverlay(ffi: gFFI)
                    : _sendWinCombo('VK_TAB')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // Editing a scheme needs the whole canvas for dragging floating keys, so
      // chrome is fully hidden then. Otherwise the three layers coexist:
      // the operation drawer, the always-visible right-edge icon rail, and the
      // minimized tool ball (only when nothing is open). The keyboard sheet is
      // a sibling of this widget in the remote page, so opening it no longer
      // hides the rail/drawer.
      if (uuState.editLayout.value) return const SizedBox.shrink();
      final drawer = uuState.drawerPage.value;
      final iconsVisible = drawer != null || uuState.railOpen.value;
      final size = MediaQuery.of(context).size;
      return Stack(
        children: [
          if (drawer != null) _drawer(context),
          if (iconsVisible) _railColumn(),
          if (drawer == null && !uuState.railOpen.value) _edgeButton(size),
        ],
      );
    });
  }

  Widget _drawer(BuildContext context) {
    final page = uuState.drawerPage.value ?? 'menu';
    // Leave the right-edge icon rail column (72 px) uncovered so the two
    // coexist; cap the width so it stays usable on small phones.
    final width = min(300.0, (MediaQuery.of(context).size.width - 72) * 0.6);
    final titles = {
      'menu': '操作',
      'schemes': '操控方案',
      'gestures': '手势与触摸',
      'gestureHelp': '手势说明',
    };
    final parent = _parentPage(page);
    return Stack(
      children: [
        // Tapping outside the drawer equals Back (one level up). Translucent so
        // drags still reach the canvas underneath instead of blocking the
        // remote mouse while the panel is open. The region stops at the right
        // edge rail (72 px) so the rail icons stay tappable while the drawer is up.
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          right: 72,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              uuState.drawerPage.value = parent;
            },
          ),
        ),
        Positioned(
          top: 0,
          bottom: 0,
          right: 72,
          width: width,
          child: Material(
        color: const Color(0xF22C2C2E),
        child: SafeArea(
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    icon: Icon(
                      page == 'menu' ? Icons.close : Icons.chevron_left,
                      color: Colors.white70,
                    ),
                    onPressed: () {
                      uuState.drawerPage.value = parent;
                    },
                  ),
                  Expanded(
                    child: Text(titles[page] ?? '',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const Divider(height: 1, color: Colors.white12),
              Expanded(
                child: page == 'menu'
                    ? _menuPage(context)
                    : page == 'schemes'
                        ? _schemesPage(context)
                        : page == 'gestureHelp'
                            ? _gestureHelpPage(context)
                            : _gesturesPage(context),
              ),
            ],
          ),
        ),
          ),
        ),
      ],
    );
  }

  // Hierarchical back: the operation card (menu) is the only top-level page;
  // schemes/gestures were opened from it, so back returns to the menu, and
  // back from the menu closes the drawer.
  String? _parentPage(String page) {
    switch (page) {
      case 'menu':
        return null;
      case 'gestureHelp':
        return 'gestures';
      default:
        return 'menu';
    }
  }

  bool _optionOn(String option) =>
      bind.sessionGetToggleOptionSync(sessionId: gFFI.sessionId, arg: option);

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(text,
          style: const TextStyle(color: Colors.white54, fontSize: 11)),
    );
  }

  Widget _card(Widget child) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF2F2F31),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: child,
    );
  }

  Widget _groupCard(String title, IconData icon, List<Widget> children) {
    final open = _expanded.contains(title);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF2F2F31),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() {
              if (!_expanded.remove(title)) _expanded.add(title);
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              child: Row(
                children: [
                  Icon(icon, color: Colors.white70, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(title,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 14)),
                  ),
                  AnimatedRotation(
                    turns: open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: const Icon(Icons.expand_more,
                        color: Colors.white54, size: 20),
                  ),
                ],
              ),
            ),
          ),
          // Keep children mounted while collapsed so their local state
          // survives a collapse/expand cycle.
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            alignment: Alignment.topCenter,
            clipBehavior: Clip.hardEdge,
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: open ? 1 : 0,
              child: Column(children: children),
            ),
          ),
        ],
      ),
    );
  }

  // Single-link card matching a _groupCard header exactly (same padding, icon
  // gap and title size), so a top-level row lines up with 显示/安全/更多.
  Widget _linkCard(IconData icon, String title, VoidCallback onTap) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF2F2F31),
        borderRadius: BorderRadius.circular(14),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              Icon(icon, color: Colors.white70, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(title,
                    style:
                        const TextStyle(color: Colors.white, fontSize: 14)),
              ),
              const Icon(Icons.chevron_right,
                  color: Colors.white38, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navRow(IconData icon, String title, VoidCallback onTap,
      {String? subtitle}) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Icon(icon, color: Colors.white70, size: 20),
      title: Text(title,
          style: const TextStyle(color: Colors.white, fontSize: 13)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle,
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
      trailing: const Icon(Icons.chevron_right, color: Colors.white38, size: 20),
      onTap: onTap,
    );
  }

  Widget _actionTile({
    required IconData icon,
    required String label,
    String? tooltip,
    bool active = false,
    bool enabled = true,
    VoidCallback? onTap,
  }) {
    final color = !enabled
        ? Colors.white30
        : active
            ? MyTheme.accent
            : Colors.white;
    Widget tile = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(
          color: active
              ? MyTheme.accent.withOpacity(0.16)
              : const Color(0xFF2F2F31),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 8),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontSize: 11)),
          ],
        ),
      ),
    );
    if (tooltip != null) {
      tile = Tooltip(message: tooltip, child: tile);
    }
    return Expanded(child: tile);
  }

  Widget _actionBar() {
    return AnimatedBuilder(
      animation: gFFI.ffiModel,
      builder: (context, _) {
        final audioOn = !_optionOn('disable-audio');
        final viewOnly = gFFI.ffiModel.viewOnly;
        return SizedBox(
          height: 96,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _actionTile(
                icon: Icons.logout,
                label: '退出远控',
                onTap: () => clientClose(gFFI.sessionId, gFFI),
              ),
              _actionTile(
                icon: Icons.high_quality_outlined,
                label: '画质',
                tooltip: '调整远端画面质量',
                onTap: _showQualityPicker,
              ),
              _actionTile(
                icon: audioOn ? Icons.volume_up : Icons.volume_off,
                label: '声音',
                tooltip: '只控制传到手机的声音，电脑扬声器照常发声',
                active: audioOn,
                onTap: () {
                  unawaited(bind.sessionToggleOption(
                      sessionId: gFFI.sessionId, value: 'disable-audio'));
                  setState(() {});
                },
              ),
              _actionTile(
                icon: viewOnly ? Icons.visibility : Icons.visibility_outlined,
                label: '仅观看',
                active: viewOnly,
                onTap: _toggleViewOnly,
              ),
              _actionTile(
                icon: Icons.picture_in_picture_alt,
                label: '小窗模式',
                enabled: false,
                onTap: () => showToast('小窗模式将在下一期支持'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _toggleViewOnly() async {
    final next = !gFFI.ffiModel.viewOnly;
    await bind.sessionToggleOption(
        sessionId: gFFI.sessionId, value: kOptionToggleViewOnly);
    if (!mounted) return;
    gFFI.ffiModel.setViewOnly(widget.id, next);
    setState(() {});
  }

  Widget _segment(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? MyTheme.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border:
              Border.all(color: selected ? MyTheme.accent : Colors.white24),
        ),
        child: Text(label,
            style: TextStyle(
                color: selected ? Colors.white : Colors.white70,
                fontSize: 12)),
      ),
    );
  }

  void _setTouchMode(bool touch) {
    if (gFFI.ffiModel.touchMode == touch) return;
    gFFI.ffiModel.toggleTouchMode();
    unawaited(bind.mainSetLocalOption(
        key: kOptionTouchMode, value: touch ? 'Y' : 'N'));
    setState(() {});
  }

  Widget _touchPointerRow() {
    return AnimatedBuilder(
      animation: gFFI.ffiModel,
      builder: (context, _) {
        final touch = gFFI.ffiModel.touchMode;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              const Icon(Icons.touch_app_outlined,
                  color: Colors.white70, size: 20),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('操作方式',
                    style: TextStyle(color: Colors.white, fontSize: 13)),
              ),
              _segment('屏幕触控', touch, () => _setTouchMode(true)),
              const SizedBox(width: 8),
              _segment('鼠标指针', !touch, () => _setTouchMode(false)),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _displayRows() {
    final pi = gFFI.ffiModel.pi;
    final rows = <Widget>[
      _toggleRow('画面缩放吸附', uuState.active.snapZoom, (v) {
        uuState.active.snapZoom = v;
      }, subtitle: '松手后吸附到适应/原始比例'),
    ];
    if (!gFFI.ffiModel.isPeerAndroid &&
        !gFFI.canvasModel.cursorEmbedded &&
        !pi.isWayland) {
      rows.add(Obx(() {
        final state = ShowRemoteCursorState.find(widget.id);
        final lock = ShowRemoteCursorLockState.find(widget.id);
        return _toggleRow('显示远端光标', state.value, (v) async {
          await bind.sessionToggleOption(
              sessionId: gFFI.sessionId, value: 'show-remote-cursor');
          state.value = bind.sessionGetToggleOptionSync(
              sessionId: gFFI.sessionId, arg: 'show-remote-cursor');
        },
            subtitle:
                gFFI.ffiModel.viewOnly || lock.value ? '当前模式下不可用' : null,
            enabled: !gFFI.ffiModel.viewOnly && !lock.value);
      }));
    }
    if (_imageQualityLoaded && _imageQuality != null) {
      rows.add(_imageQualitySection());
    }
    return rows;
  }

  List<Widget> _securityRows() {
    final hostControl = _hostControlSupported;
    final muted = _hostIntent('mute');
    final restoreAudio = _hostIntent('restore-audio');
    final displayMode = _hostSetting('display', '1920x1080');
    return [
      Builder(builder: (context) {
        final subtitle = _mutePending
            ? Row(children: [
                const SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white70),
                ),
                const SizedBox(width: 8),
                Text(muted ? '正在静音…' : '正在恢复声音…',
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 11)),
              ])
            : Text(
                hostControl
                    ? '静音被控端扬声器（不影响远程串流）'
                    : '需被控端为本项目编译版 RustDesk',
                style: const TextStyle(color: Colors.white38, fontSize: 11));
        return SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title:
              const Text('电脑静音', style: TextStyle(color: Colors.white, fontSize: 13)),
          subtitle: subtitle,
          value: hostControl && muted,
          onChanged: _mutePending
              ? null
              : (v) {
                  if (!hostControl) {
                    showToast('需被控端为本项目编译版 RustDesk');
                    return;
                  }
                  _toggleMute(v);
                },
        );
      }),
      Obx(() {
        final state = PrivacyModeState.find(widget.id);
        final on = state.value.isNotEmpty;
        return _PrivacyModeTile(
          on: on,
          pending: _privacyPendingOn,
          awaitUnlock: _privacyAwaitUnlock,
          recovering: _privacyAutoRecovering && _hostIntent('privacy'),
          supported: _privacySupported(),
          onChanged: _togglePrivacy,
        );
      }),
      _toggleRow('断开后恢复声音', hostControl && restoreAudio, (v) {
        if (!hostControl) return;
        setState(() {
          _setHostIntent('restore-audio', v);
          _sendHostCmd('restore-audio', v);
        });
      },
          subtitle: hostControl
              ? (restoreAudio ? '断开后把扬声器还原成连接前的状态' : '断开后保持静音，长期有效')
              : '需被控端为本项目编译版 RustDesk'),
      if (hostControl)
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: const Text('虚拟屏分辨率',
              style: TextStyle(color: Colors.white, fontSize: 13)),
          subtitle: Text('当前 $displayMode · 下次开启关屏时生效',
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
          trailing:
              const Icon(Icons.chevron_right, color: Colors.white54, size: 18),
          onTap: () async {
            const modes = {
              '1280x720': '1280×720',
              '1536x864': '1536×864',
              '1920x1080': '1920×1080',
              '2560x1440': '2560×1440',
            };
            final picked = await showDialog<String>(
              context: context,
              builder: (ctx) => SimpleDialog(
                title: const Text('虚拟屏分辨率'),
                children: modes.entries
                    .map((e) => SimpleDialogOption(
                          onPressed: () => Navigator.of(ctx).pop(e.key),
                          child: Text('${e.value}${e.key == displayMode ? '  ✓' : ''}'),
                        ))
                    .toList(),
              ),
            );
            if (picked == null || !mounted) return;
            _setHostSetting('display', picked);
            final (w, h) = _parseDisplayMode(picked);
            _sendHostCmd('display:${w}x$h', true);
            setState(() {});
          },
        ),
      _toggleRow('退出远控时锁定电脑', _optionOn('lock-after-session-end'), (v) {
        unawaited(bind.sessionToggleOption(
            sessionId: gFFI.sessionId, value: 'lock-after-session-end'));
      }),
      _AutoUnlockTile(id: widget.id),
    ];
  }

  // UU-style keymap section: a master switch inside the operation card that
  // inline-expands three rows when on. This replaces the old second-level
  // "启用按键映射" page; the real gate is uuState.keyMapEnabled (floating keys).
  Widget _keymapMasterRow() {
    return Obx(() => SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          secondary: const Icon(Icons.keyboard_alt_outlined,
              color: Colors.white70, size: 20),
          title: const Text('启用按键映射',
              style: TextStyle(color: Colors.white, fontSize: 13)),
          subtitle: Text(
              uuState.keyMapEnabled.value
                  ? '悬浮键已启用，点击即发送到电脑'
                  : '已关闭，悬浮键隐藏（方案配置保留）',
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
          value: uuState.keyMapEnabled.value,
          onChanged: (v) {
            uuState.keyMapEnabled.value = v;
            uuState.save();
          },
        ));
  }

  Widget _keymapExpanded() {
    final scheme = uuState.active;
    final moreOpen = _expanded.contains(_kKeymapMoreKey);
    return Column(
      children: [
        Obx(() => _navRow(Icons.swap_horiz, '切换操控方案', () {
              uuState.drawerPage.value = 'schemes';
            }, subtitle: '当前方案：${uuState.activeName.value}')),
        _navRow(Icons.edit_outlined, '编辑当前方案', () {
          uuState.activeName.value = scheme.name;
          uuState.drawerPage.value = null;
          uuState.keyboardOpen.value = false;
          uuState.editLayout.value = true;
          uuState.save();
        }),
        _navRow(Icons.tune, '其他设置', () {
          setState(() {
            if (!_expanded.remove(_kKeymapMoreKey)) {
              _expanded.add(_kKeymapMoreKey);
            }
          });
        }),
        // Plain conditional, not a second AnimatedSize: nesting AnimatedSize
        // made the outer wrapper cache a mid-animation height, so the
        // expanded rows overflowed the controls below (二级/一级 重叠).
        if (moreOpen)
          _sliderRow('按键放大', scheme.keyScale, 0.7, 1.6, (v) {
            scheme.keyScale = v;
          }),
        if (moreOpen)
          _toggleRow('点击按键时震动', scheme.haptics, (v) {
            scheme.haptics = v;
          }),
      ],
    );
  }

  List<Widget> _moreRows(BuildContext context) {
    return [
      _navRow(Icons.tv, '会话设置', () {
        uuState.drawerPage.value = null;
        showOptions(context, widget.id, gFFI.dialogManager);
      }),
      _navRow(Icons.more_vert, '更多操作', () {
        uuState.drawerPage.value = null;
        widget.onShowActions();
      }),
    ];
  }

  // UU-style safety nudge above the action bar: the host speaker is still
  // audible or the physical screen is still on.
  Widget _securityHint() {
    return Obx(() {
      final _ = uuState.hostStateVersion.value; // mute intent follows host replies
      final muteOff = _hostControlSupported && !_hostIntent('mute');
      final screenOff = _privacySupported() &&
          PrivacyModeState.find(widget.id).value.isEmpty &&
          _privacyPendingOn != true;
      if (!muteOff && !screenOff) return const SizedBox.shrink();
      return const Padding(
        padding: EdgeInsets.fromLTRB(4, 2, 4, 10),
        child: Row(children: [
          Icon(Icons.error_outline, size: 16, color: Color(0xFFFFA726)),
          SizedBox(width: 6),
          Text('隐私安全状态需关注',
              style: TextStyle(color: Color(0xFFFFA726), fontSize: 13)),
        ]),
      );
    });
  }

  Widget _menuPage(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        _securityHint(),
        _actionBar(),
        const SizedBox(height: 20),
        _sectionLabel('操作'),
        _card(Obx(() => Column(
          children: [
            _keymapMasterRow(),
            // Hard conditional, deliberately NOT AnimatedSize/Align(heightFactor):
            // the collapsing trick only shrank the layout height while the rows
            // still painted, and this card has no clip, so the expanded rows bled
            // over the "操作方式" row below (重叠). Off = not in the tree at all.
            if (uuState.keyMapEnabled.value) _keymapExpanded(),
            if (!gFFI.ffiModel.isPeerAndroid) _touchPointerRow(),
          ],
        ))),
        const SizedBox(height: 12),
        _groupCard('显示', Icons.monitor_outlined, _displayRows()),
        _groupCard('安全', Icons.shield_outlined, _securityRows()),
        // 外设 分组只剩「手势与触摸」一行，用与分组标题同款排版直接呈现。
        _linkCard(Icons.touch_app_outlined, '手势与触摸', () {
          uuState.drawerPage.value = 'gestures';
        }),
        _groupCard('更多', Icons.more_horiz, _moreRows(context)),
      ],
    );
  }

  Widget _gesturesPage(BuildContext context) {
    final scheme = uuState.active;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        _card(Column(
          children: [
            _navRow(Icons.help_outline, '查看手势说明', () {
              uuState.drawerPage.value = 'gestureHelp';
            }),
            _toggleRow('双指缩放', scheme.pinchZoom, (v) {
              scheme.pinchZoom = v;
            }, subtitle: '关闭后双指始终按滚动处理'),
            _sliderRow('滚动灵敏度', scheme.scrollSensitivity, 0.5, 3.0, (v) {
              scheme.scrollSensitivity = v;
            }),
          ],
        )),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 12, 4, 0),
          child: Text('灵敏度过高时慢速滑动容易越过目标行，过低时需要反复滑动。',
              style: TextStyle(color: Colors.white38, fontSize: 11)),
        ),
      ],
    );
  }

  // UU-styled gesture reference. Replaces the upstream GestureHelp bottom bar
  // (which was opening as a full-width overlay with no way back once the drawer
  // closed). Lives inside the drawer so the header's back chevron returns to
  // 手势与触摸. Descriptions reflect THIS build's engine, not upstream's.
  Widget _gestureHelpPage(BuildContext context) {
    Widget row(IconData icon, String title, String desc) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Colors.white70, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(color: Colors.white, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(desc,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        _card(Column(
          children: [
            row(Icons.touch_app_outlined, '单指轻点', '远端鼠标左键单击'),
            row(Icons.touch_app, '单指长按', '远端鼠标右键'),
            row(Icons.open_with, '单指拖动', '按住并拖动鼠标'),
            row(Icons.swap_vert, '双指竖直滑动', '远端滚轮（上下滚动）'),
            row(Icons.pan_tool_outlined, '双指水平滑动', '平移画布视图'),
            row(Icons.pinch, '双指捏合', '画布缩放（可在上一页关闭）'),
            row(Icons.back_hand_outlined, '三指滑动', '交给系统截屏，不发送到电脑'),
          ],
        )),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 12, 4, 0),
          child: Text('手势判定会向滑动方向温和收紧；判错时多为双指张开误触缩放，可在上一页关闭「双指缩放」。',
              style: TextStyle(color: Colors.white38, fontSize: 11)),
        ),
      ],
    );
  }

  Widget _schemesPage(BuildContext context) {
    return Obx(() {
      final schemes = uuState.schemes;
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text('点按卡片切换方案',
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.5), fontSize: 11)),
                ),
                TextButton.icon(
                  onPressed: () => _newScheme(context),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('新建'),
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: schemes.length,
              itemBuilder: (ctx, index) {
                final scheme = schemes[index];
                final active = scheme.name == uuState.activeName.value;
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3A3A3C),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: active ? MyTheme.accent : Colors.transparent),
                  ),
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.keyboard, color: Colors.white70),
                    title: Text(scheme.name,
                        style: TextStyle(
                            color: active ? MyTheme.accent : Colors.white,
                            fontSize: 14)),
                    subtitle: Text('${scheme.keys.length} 个悬浮键',
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11)),
                    onTap: () {
                      uuState.activeName.value = scheme.name;
                      uuState.save();
                    },
                    trailing: PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert,
                          color: Colors.white54, size: 20),
                      onSelected: (v) => _schemeAction(v, index),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('编辑布局')),
                        PopupMenuItem(value: 'rename', child: Text('重命名')),
                        PopupMenuItem(value: 'delete', child: Text('删除')),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      );
    });
  }

  Future<void> _schemeAction(String action, int index) async {
    final scheme = uuState.schemes[index];
    switch (action) {
      case 'edit':
        uuState.activeName.value = scheme.name;
        uuState.drawerPage.value = null;
        uuState.keyboardOpen.value = false;
        uuState.editLayout.value = true;
        uuState.save();
        break;
      case 'rename':
        final controller = TextEditingController(text: scheme.name);
        final name = await _withIme(() => showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('方案名称'),
            content: TextField(controller: controller, autofocus: true),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('取消')),
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
                  child: const Text('确定')),
            ],
          ),
        ));
        if (name == null || name.isEmpty || !mounted) return;
        if (uuState.schemes.any((s) => s.name == name && s != scheme)) return;
        setState(() {
          if (uuState.activeName.value == scheme.name) {
            uuState.activeName.value = name;
          }
          scheme.name = name;
        });
        uuState.save();
        break;
      case 'delete':
        if (uuState.schemes.length <= 1) return;
        final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('删除方案'),
            content: Text('确定删除「${scheme.name}」？'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('取消')),
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('删除')),
            ],
          ),
        );
        if (confirm != true || !mounted) return;
        setState(() {
          uuState.schemes.removeAt(index);
          if (uuState.activeName.value == scheme.name) {
            uuState.activeName.value = uuState.schemes.first.name;
          }
        });
        uuState.save();
        break;
    }
  }

  Future<void> _newScheme(BuildContext context) async {
    final controller = TextEditingController(text: '新方案');
    final name = await _withIme(() => showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建方案'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              child: const Text('确定')),
        ],
      ),
    ));
    if (name == null || name.isEmpty || !mounted) return;
    if (uuState.schemes.any((s) => s.name == name)) return;
    setState(() {
      uuState.schemes.add(UuScheme(name: name));
      uuState.activeName.value = name;
    });
    uuState.save();
  }

  Widget _sliderRow(String label, double value, double min, double max,
      ValueChanged<double> onChanged) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: (v) {
                setState(() => onChanged(v));
              },
              onChangeEnd: (_) => uuState.save(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _toggleRow(String label, bool value, ValueChanged<bool> onChanged,
      {String? subtitle, bool enabled = true}) {
    return SwitchListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      title: Text(label,
          style: const TextStyle(color: Colors.white, fontSize: 13)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle,
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
      value: value,
      onChanged: enabled
          ? (v) {
              setState(() => onChanged(v));
              uuState.save();
            }
          : null,
    );
  }

}

class _PrivacyModeTile extends StatelessWidget {
  final bool on;
  final bool? pending;
  final bool awaitUnlock;
  final bool recovering;
  final bool supported;
  final ValueChanged<bool> onChanged;

  const _PrivacyModeTile({
    required this.on,
    required this.pending,
    required this.awaitUnlock,
    required this.recovering,
    required this.supported,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final spinning = pending != null;
    final awaitText = (spinning && awaitUnlock) || recovering;
    final subtitle = spinning
        ? Row(children: [
            const SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white70),
            ),
            const SizedBox(width: 8),
            Text(awaitUnlock ? '等待被控端解锁后自动开启' : (pending! ? '正在开启…' : '正在关闭…'),
                style: const TextStyle(color: Colors.white54, fontSize: 11)),
          ])
        : awaitText
            ? const Text('等待被控端解锁后自动开启',
                style: TextStyle(color: Colors.white54, fontSize: 11))
            : supported
                ? const Text('断开物理显示器，画面切到虚拟屏',
                    style: TextStyle(color: Colors.white38, fontSize: 11))
                : const Text('需被控端安装并以服务运行官方 RustDesk',
                    style: TextStyle(color: Colors.white38, fontSize: 11));
    return SwitchListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      title: const Text('操控时物理关屏（虚拟屏防窥）',
          style: TextStyle(color: Colors.white, fontSize: 13)),
      subtitle: subtitle,
      value: pending ?? (awaitUnlock || recovering || on),
      onChanged: onChanged,
    );
  }
}

class _AutoUnlockTile extends StatefulWidget {
  final String id;

  const _AutoUnlockTile({required this.id});

  @override
  State<_AutoUnlockTile> createState() => _AutoUnlockTileState();
}

class _AutoUnlockTileState extends State<_AutoUnlockTile> {
  Map<String, dynamic> _cfg = {};
  String _pwd = '';
  bool _decryptFailed = false;

  @override
  void initState() {
    super.initState();
    _cfg = AutoUnlockConfig.load(widget.id);
    _loadPassword();
  }

  Future<void> _loadPassword() async {
    final enc = _cfg['enc']?.toString() ?? '';
    final pwd = await AutoUnlockConfig.password(_cfg);
    if (!mounted) return;
    setState(() {
      _pwd = pwd ?? '';
      _decryptFailed = enc.isNotEmpty && pwd == null;
    });
    if ((_cfg['pwd']?.toString() ?? '').isNotEmpty) {
      AutoUnlockConfig.migrate(widget.id, _cfg).then((ok) {
        if (ok && mounted) setState(() {});
      });
    }
  }

  void _store() => AutoUnlockConfig.save(widget.id, _cfg);

  static String _wsCodes(String s) {
    final codes = <String>[];
    for (final r in s.runes) {
      if (String.fromCharCode(r).trim().isEmpty) {
        codes.add('U+${r.toRadixString(16).toUpperCase().padLeft(4, '0')}');
      }
    }
    return codes.join(' / ');
  }

  static bool _hasFullWidthSpace(String s) => s.contains('\u3000');

  static String _pwdSummary(String pwd) {
    if (pwd.isEmpty) return '未设置';
    if (_hasFullWidthSpace(pwd)) {
      return '已设置（含全角空格 U+3000，Windows 登录不认，请重设）';
    }
    if (pwd.trim().isEmpty) {
      return '已设置（长度 ${pwd.length}，空格 ${_wsCodes(pwd)}）';
    }
    return '已设置（${pwd.length} 个字符）';
  }

  Future<T?> _withIme<T>(Future<T?> Function() run) async {
    await gFFI.invokeMethod("enable_soft_keyboard", true);
    try {
      return await run();
    } finally {
      if (mounted) gFFI.invokeMethod("enable_soft_keyboard", false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pwd = _pwd;
    final supported = gFFI.ffiModel.pi.platform == kPeerPlatformWindows &&
        gFFI.ffiModel.pi.platformAdditions['uu_auto_unlock'] == true;
    return Column(
      children: [
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: const Text('连接后自动输入密码解锁',
              style: TextStyle(color: Colors.white, fontSize: 13)),
          value: _cfg['on'] == true,
          onChanged: (v) {
            setState(() => _cfg['on'] = v);
            _store();
          },
        ),
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: const Text('登录密码',
              style: TextStyle(color: Colors.white, fontSize: 13)),
          subtitle: Text(
              _decryptFailed
                  ? '已保存的密码无法解密（应用数据可能被清除），请重设'
                  : _pwdSummary(pwd),
              style: TextStyle(
                  color: _decryptFailed || _hasFullWidthSpace(pwd)
                      ? Colors.amber
                      : Colors.white38,
                  fontSize: 11)),
          trailing: const Icon(Icons.edit, color: Colors.white54, size: 18),
          onTap: () async {
            final controller = TextEditingController(text: pwd);
            final ok = await _withIme(() => showDialog<bool>(
              context: context,
              builder: (ctx) => StatefulBuilder(
                builder: (ctx, setDlgState) => AlertDialog(
                  title: const Text('Windows 登录密码'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: controller,
                        obscureText: true,
                        autofocus: true,
                        keyboardType: TextInputType.visiblePassword,
                        autocorrect: false,
                        enableSuggestions: false,
                        smartDashesType: SmartDashesType.disabled,
                        smartQuotesType: SmartQuotesType.disabled,
                        onChanged: (_) => setDlgState(() {}),
                        decoration: const InputDecoration(
                            hintText: '使用系统密钥库加密保存在本机'),
                      ),
                      const SizedBox(height: 10),
                      Row(children: [
                        OutlinedButton(
                          onPressed: () {
                            controller.text += ' ';
                            setDlgState(() {});
                          },
                          child: const Text('插入空格'),
                        ),
                        const SizedBox(width: 10),
                        Text('长度 ${controller.text.length}',
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 12)),
                      ]),
                      if (controller.text.isNotEmpty &&
                          controller.text.trim().isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                              controller.text
                                          .codeUnits
                                          .every((c) => c == 0x20)
                                  ? '码点：U+0020（半角空格）'
                                  : '码点：${_wsCodes(controller.text)}（必须为 U+0020）',
                              style: TextStyle(
                                  color: controller.text.codeUnits
                                          .every((c) => c == 0x20)
                                      ? Colors.white54
                                      : Colors.amber,
                                  fontSize: 11)),
                        ),
                    ],
                  ),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('取消')),
                    TextButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text('确定')),
                  ],
                ),
              ),
            ));
            if (ok != true || !mounted) return;
            final plain = controller.text;
            if (plain.isEmpty) {
              setState(() {
                _cfg.remove('enc');
                _cfg.remove('pwd');
                _pwd = '';
                _decryptFailed = false;
              });
              _store();
              return;
            }
            final enc = await AutoUnlockConfig.encrypt(plain);
            if (enc == null) {
              if (mounted) showToast('无法安全保存密码：需要 Android 6.0 以上');
              return;
            }
            setState(() {
              _cfg['enc'] = enc;
              _cfg.remove('pwd');
              _pwd = plain;
              _decryptFailed = false;
            });
            _store();
          },
        ),
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          enabled: supported && _pwd.isNotEmpty,
          title: const Text('立即尝试解锁',
              style: TextStyle(color: Colors.white, fontSize: 13)),
          subtitle: const Text('仅在电脑锁屏时注入；主机最多自动重试 3 次',
              style: TextStyle(color: Colors.white38, fontSize: 11)),
          trailing: Icon(Icons.lock_open,
              color: supported && _pwd.isNotEmpty
                  ? Colors.white54
                  : Colors.white24,
              size: 18),
          onTap: () async {
            final sid = gFFI.sessionId;
            bind.sessionTogglePrivacyMode(
                sessionId: sid,
                implKey: 'uu:unlock:${base64Encode(utf8.encode(_pwd))}',
                on: true);
            showToast('已发送解锁指令');
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
              supported
                  ? '连接后由主机判断是否锁屏并在锁屏上输入密码，未锁屏不会注入；失败自动重试。'
                  : '当前主机版本不支持闭环自动解锁，将退回旧的一次性输入方式。',
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
        ),
      ],
    );
  }
}
