// Engine_Ooze.sc  –  v2
// One-shot + granular + loop/overdub, 8 banks, threshold detection
//
// SynthDefs:  ooze_rec  ooze_play  ooze_gran  ooze_loop_play  ooze_loop_rec  ooze_thresh
// All buffers are mono, 20 s each.  Loop play/rec share the same buffers as one-shots.

Engine_Ooze : CroneEngine {

  var bufs;           // 8 × Buffer
  var recSynths;      // per-bank one-shot record synth
  var loopPlaySynths; // per-bank continuous loop playback synth
  var loopRecSynths;  // per-bank loop record / overdub synth
  var threshSynth;    // single threshold detector
  var sineSynths;     // 4 persistent sine drone synths
  var numBanks, bufDur, luaAddr;

  *new { arg context, doneCallback;
    ^super.new(context, doneCallback);
  }

  alloc {
    var s = context.server;
    numBanks = 8;
    bufDur   = 20;

    // matron (Lua) OSC address
    luaAddr = NetAddr("127.0.0.1", 10111);

    bufs           = Array.fill(numBanks, { Buffer.alloc(s, (s.sampleRate * bufDur).round.asInteger, 1) });
    recSynths      = Array.newClear(numBanks);
    loopPlaySynths = Array.newClear(numBanks);
    loopRecSynths  = Array.newClear(numBanks);
    threshSynth    = nil;

    // ─── ONE-SHOT RECORDING ───────────────────────────────────────────────────────────────────────────
    SynthDef(\ooze_rec, {
      arg buf = 0, gate = 1;
      var sig = SoundIn.ar([0, 1]).mean;
      var env = EnvGen.kr(Env.asr(0.01, 1.0, 0.05), gate, doneAction: Done.freeSelf);
      RecordBuf.ar(sig * env, buf, loop: 0, doneAction: Done.none);
    }).add;

    // ─── ONE-SHOT PLAYBACK ───────────────────────────────────────────────────────────────────────────
    // rate    : playback rate (pitch shift as 2^(n/12))
    // reverse : 0=forward 1=backward (reads from tail with negative rate)
    // crush   : 0–1, sample-rate reduction (bitcrush character)
    // dist    : 0–1, waveshape saturation
    // rev_mix : 0–1, FreeVerb wet mix
    SynthDef(\ooze_play, {
      arg buf=0, out=0,
          rate=1, amp=0.7, atk=0.005, dec=0.4,
          rev_mix=0, dist=0, crush=0, reverse=0;

      var sig, env, startPos, actualRate, sr_reduced, driven, verb;

      startPos   = Select.kr(reverse, [0, BufFrames.kr(buf) - 2]);
      actualRate = rate * BufRateScale.kr(buf) * Select.kr(reverse, [1.0, -1.0]);

      env = EnvGen.kr(Env.perc(atk, dec, 1.0, -3.5), doneAction: Done.freeSelf);
      sig = PlayBuf.ar(1, buf, actualRate, startPos: startPos, doneAction: Done.none);

      // Bitcrush: blend between clean and sample-rate-reduced signal
      sr_reduced = Latch.ar(sig, Impulse.ar((SampleRate.ir * (1.0 - crush * 0.97)).max(180)));
      sig        = sig + ((sr_reduced - sig) * crush);

      // Soft saturation waveshaper; compensate gain
      driven = (sig * (1.0 + dist * 22.0)).tanh * (1.0 / (1.0 + dist * 0.90).max(0.1));
      sig    = sig + ((driven - sig) * dist);

      sig  = sig * env * amp;
      verb = FreeVerb.ar(sig, 1.0, 0.60 + rev_mix * 0.35, 0.50);
      sig  = sig + (verb * rev_mix);
      sig  = Pan2.ar(sig, Rand(-0.35, 0.35));
      Out.ar(out, sig);
    }).add;

    // ─── GRANULAR PLAYBACK ───────────────────────────────────────────────────────────────────────────
    // TGrains with wandering position, randomised grain size & pan.
    // Stereo output; reverb applied via mono mix + duplicate.
    SynthDef(\ooze_gran, {
      arg buf=0, out=0,
          rate=1, amp=0.5, rev_mix=0, dist=0, crush=0, dur=0.5;

      var trig, sig, env, sr_reduced, driven, mono, verb;
      var grain_hz = LFNoise0.kr(0.4).range(9.0, 22.0);

      trig = Impulse.ar(grain_hz);
      sig  = TGrains.ar(
        numChannels: 2,
        trigger:     trig,
        bufnum:      buf,
        rate:        rate * BufRateScale.kr(buf),
        centerPos:   LFNoise1.kr(2.2).range(0.05, 0.92) * BufDur.kr(buf),
        dur:         LFNoise0.kr(5).range(0.04, 0.20),
        pan:         LFNoise0.kr(grain_hz * 0.6).range(-0.65, 0.65),
        amp:         amp * 0.52,
        interp:      4
      );

      env = EnvGen.kr(Env.perc(0.03, dur, 1.0, -2.5), doneAction: Done.freeSelf);

      // Bitcrush (MC expansion handles stereo)
      sr_reduced = Latch.ar(sig, Impulse.ar((SampleRate.ir * (1.0 - crush * 0.97)).max(180)));
      sig        = sig + ((sr_reduced - sig) * crush);

      // Distortion (MC expansion)
      driven = (sig * (1.0 + dist * 18.0)).tanh * (1.0 / (1.0 + dist * 0.88).max(0.1));
      sig    = sig + ((driven - sig) * dist);

      sig  = sig * env;

      // Reverb on mono mix, added back to stereo
      mono = (sig[0] + sig[1]) * 0.5;
      verb = FreeVerb.ar(mono, 1.0, 0.82, 0.60);
      sig  = sig + (verb ! 2 * rev_mix);

      Out.ar(out, sig);
    }).add;

    // ─── BUFFER CROSSFADE ──────────────────────────────────────────────────────────────────────────
    // Bakes a linear crossfade into the buffer after recording stops.
    // Blends the TAIL (fading out) into the HEAD (fading in) so the loop
    // point is seamless.  Runs for exactly xfade_frames samples then frees.
    SynthDef(\ooze_xfade, {
      arg buf=0, loop_frames=48000, xfade_frames=1920;
      var phase    = Phasor.ar(0, 1, 0, xfade_frames);
      var fade_in  = phase / xfade_frames.max(1);
      var fade_out = 1.0 - fade_in;
      var tail_pos = (loop_frames - xfade_frames) + phase;
      var head_sig = BufRd.ar(1, buf, phase,    0, 4);
      var tail_sig = BufRd.ar(1, buf, tail_pos, 0, 4);
      var blended  = (head_sig * fade_in) + (tail_sig * fade_out);
      BufWr.ar(blended, buf, phase, 0);
      Line.kr(0, 1, xfade_frames / SampleRate.ir, doneAction: Done.freeSelf);
    }).add;

    // ─── LOOP PLAYBACK ───────────────────────────────────────────────────────────────────────────
    // rate: tempo-correction multiplier (1.0 = original, <1 = slightly slow,
    //       >1 = slightly fast).  Max useful range ±8% = inaudible pitch shift.
    SynthDef(\ooze_loop_play, {
      arg buf=0, out=0, amp=0.82, loop_frames=48000, rate=1.0;
      var phase = Phasor.ar(0, rate * BufRateScale.kr(buf), 0, loop_frames.max(1));
      var sig   = BufRd.ar(1, buf, phase, 1, 4);
      sig = sig * amp;
      Out.ar(out, sig ! 2);
    }).add;

    // ─── LOOP RECORD / OVERDUB ──────────────────────────────────────────────────────────────────────
    // pre_level=0 → overwrite   pre_level=1 → overdub
    // loop=1 so RecordBuf wraps indefinitely until freed
    SynthDef(\ooze_loop_rec, {
      arg buf=0, rec_level=1, pre_level=0, gate=1;
      var sig = SoundIn.ar([0, 1]).mean;
      var env = EnvGen.kr(Env.asr(0.01, 1.0, 0.05), gate, doneAction: Done.freeSelf);
      RecordBuf.ar(sig * env, buf, rec_level, pre_level, 1, 1, doneAction: Done.none);
    }).add;

    // ─── THRESHOLD DETECTOR ──────────────────────────────────────────────────────────────────────────
    // Fires once when input amplitude crosses thresh, then resets.
    // SendReply → OSCdef → Lua via port 10111.
    SynthDef(\ooze_thresh, {
      arg thresh=0.04;
      var sig   = SoundIn.ar([0, 1]).mean;
      var level = Amplitude.kr(sig, 0.005, 0.10);
      var gate  = SetResetFF.kr(level > thresh, level < (thresh * 0.4));
      SendReply.kr(gate, '/ooze_thresh_sc', [level]);
    }).add;

    // ─── SINE DRONE ───────────────────────────────────────────────────────────────────────────────
    SynthDef(\ooze_sine, {
      arg out=0, hz=220, vol=0.0, pan=0.0,
          fm_ratio=2.0, fm_index=0.0, vol_lag=0.5;
      var mod = SinOsc.ar(hz * fm_ratio) * hz * fm_index;
      var car = SinOsc.ar(hz + mod) * 0.25;
      var vol_ = Lag.kr(vol, vol_lag);
      Out.ar(out, Pan2.ar(car * vol_, pan));
    }).add;

    // ─── GLUT GRANULAR ─────────────────────────────────────────────────────────────────────────────
    SynthDef(\ooze_glut, {
      arg buf=0, out=0, rate=1.0, amp=0.6, rev_mix=0.0,
          pos=0.0, speed=1.0, jitter=0.3, size=0.12, density=20.0,
          pitch=1.0, pan=0.0, spread=0.3, envscale=2.0, gate=1;
      var trig    = Impulse.kr(density);
      var buf_dur = BufDur.kr(buf);
      var jitter_sig = TRand.kr(jitter.neg, jitter, trig) * buf_dur.reciprocal;
      var pan_sig    = TRand.kr(spread.neg, spread, trig);
      var buf_pos    = Phasor.kr(0, buf_dur.reciprocal / ControlRate.ir * speed, pos, 1.0);
      var pos_sig    = Wrap.kr(buf_pos + jitter_sig);
      var sig_l = GrainBuf.ar(1, trig, size, buf, pitch * BufRateScale.kr(buf), pos_sig, 2);
      var sig_r = GrainBuf.ar(1, trig, size, buf, pitch * BufRateScale.kr(buf), pos_sig, 2);
      var sig   = Balance2.ar(sig_l, sig_r, pan + pan_sig);
      var env   = EnvGen.kr(Env.asr(0.05, 1.0, 0.5), gate:gate, timeScale:envscale, doneAction:Done.freeSelf);
      var mono  = (sig[0] + sig[1]) * 0.5;
      var verb  = FreeVerb.ar(mono, 1.0, 0.80, 0.55);
      sig = sig + (verb ! 2 * rev_mix);
      Out.ar(out, sig * env * amp);
    }).add;

    // SC → Lua relay
    OSCdef(\ooze_thresh_relay, { |msg|
      luaAddr.sendMsg("/ooze_thresh", msg[3]);
    }, '/ooze_thresh_sc');

    s.sync;

    // ─── SINE DRONE SYNTHS ────────────────────────────────────────────────────────────────────────
    sineSynths = Array.fill(4, { |i|
      Synth(\ooze_sine, [
        \out, context.out_b.index,
        \hz, 220.0,
        \vol, 0.0,
        \pan, (i - 1.5) / 1.5 * 0.6
      ], context.xg)
    });

    // ─── COMMANDS ─────────────────────────────────────────────────────────────────────────────────

    // One-shot recording ───────────────────────────────────────────────────────────────────────
    this.addCommand("rec_start", "i", { arg msg;
      var bank = msg[1].asInteger.clip(0, numBanks - 1);
      if (recSynths[bank].notNil) { recSynths[bank].free };
      bufs[bank].zero;
      recSynths[bank] = Synth(\ooze_rec, [\buf, bufs[bank].bufnum, \gate, 1], context.xg);
    });

    this.addCommand("rec_stop", "i", { arg msg;
      var bank = msg[1].asInteger.clip(0, numBanks - 1);
      if (recSynths[bank].notNil) { recSynths[bank].set(\gate, 0); recSynths[bank] = nil };
    });

    this.addCommand("normalize", "i", { arg msg;
      bufs[msg[1].asInteger.clip(0, numBanks - 1)].normalize(1.0);
    });

    // One-shot playback ──────────────────────────────────────────────────────────────────────
    // args: bank  rate  amp  atk  dec  rev_mix  dist  crush  reverse
    this.addCommand("play", "ifffffffi", { arg msg;
      var bank = msg[1].asInteger.clip(0, numBanks - 1);
      Synth(\ooze_play, [
        \buf,     bufs[bank].bufnum,
        \out,     context.out_b.index,
        \rate,    msg[2].asFloat,
        \amp,     msg[3].asFloat,
        \atk,     msg[4].asFloat,
        \dec,     msg[5].asFloat,
        \rev_mix, msg[6].asFloat,
        \dist,    msg[7].asFloat,
        \crush,   msg[8].asFloat,
        \reverse, msg[9].asInteger
      ], context.xg);
    });

    // Granular playback ────────────────────────────────────────────────────────────────────
    // args: bank  rate  amp  rev_mix  dist  crush  dur
    this.addCommand("play_gran", "iffffff", { arg msg;
      var bank = msg[1].asInteger.clip(0, numBanks - 1);
      Synth(\ooze_gran, [
        \buf,     bufs[bank].bufnum,
        \out,     context.out_b.index,
        \rate,    msg[2].asFloat,
        \amp,     msg[3].asFloat,
        \rev_mix, msg[4].asFloat,
        \dist,    msg[5].asFloat,
        \crush,   msg[6].asFloat,
        \dur,     msg[7].asFloat
      ], context.xg);
    });

    // Loop record / overdub ────────────────────────────────────────────────────────────────
    this.addCommand("loop_rec_start", "i", { arg msg;
      var bank = msg[1].asInteger.clip(0, numBanks - 1);
      if (loopRecSynths[bank].notNil) { loopRecSynths[bank].free };
      bufs[bank].zero;
      loopRecSynths[bank] = Synth(\ooze_loop_rec,
        [\buf, bufs[bank].bufnum, \rec_level, 1, \pre_level, 0, \gate, 1], context.xg);
    });

    this.addCommand("loop_rec_stop", "i", { arg msg;
      var bank = msg[1].asInteger.clip(0, numBanks - 1);
      if (loopRecSynths[bank].notNil) { loopRecSynths[bank].set(\gate, 0); loopRecSynths[bank] = nil };
    });

    this.addCommand("loop_overdub_on", "i", { arg msg;
      var bank = msg[1].asInteger.clip(0, numBanks - 1);
      if (loopRecSynths[bank].notNil) { loopRecSynths[bank].free };
      loopRecSynths[bank] = Synth(\ooze_loop_rec,
        [\buf, bufs[bank].bufnum, \rec_level, 1, \pre_level, 1, \gate, 1], context.xg);
    });

    this.addCommand("loop_overdub_off", "i", { arg msg;
      var bank = msg[1].asInteger.clip(0, numBanks - 1);
      if (loopRecSynths[bank].notNil) { loopRecSynths[bank].set(\gate, 0); loopRecSynths[bank] = nil };
    });

    // Crossfade bake (run after rec_stop, before play_start) ───────────────────────
    // args: bank  loop_frames  xfade_frames
    this.addCommand("loop_xfade", "iii", { arg msg;
      var bank         = msg[1].asInteger.clip(0, numBanks - 1);
      var loop_frames  = msg[2].asInteger.max(1);
      var xfade_frames = msg[3].asInteger.max(64);
      Synth(\ooze_xfade, [
        \buf,          bufs[bank].bufnum,
        \loop_frames,  loop_frames,
        \xfade_frames, xfade_frames
      ], context.xg);
    });

    // args: bank  loop_frames  rate
    this.addCommand("loop_play_start", "iif", { arg msg;
      var bank = msg[1].asInteger.clip(0, numBanks - 1);
      var lf   = msg[2].asInteger.max(1);
      var rate = msg[3].asFloat;
      if (loopPlaySynths[bank].notNil) { loopPlaySynths[bank].free };
      loopPlaySynths[bank] = Synth(\ooze_loop_play, [
        \buf,         bufs[bank].bufnum,
        \out,         context.out_b.index,
        \amp,         0.82,
        \loop_frames, lf,
        \rate,        rate
      ], context.xg);
    });

    this.addCommand("loop_play_stop", "i", { arg msg;
      var bank = msg[1].asInteger.clip(0, numBanks - 1);
      if (loopPlaySynths[bank].notNil) { loopPlaySynths[bank].free; loopPlaySynths[bank] = nil };
    });

    this.addCommand("loop_clear", "i", { arg msg;
      var bank = msg[1].asInteger.clip(0, numBanks - 1);
      if (loopRecSynths[bank].notNil)  { loopRecSynths[bank].free;  loopRecSynths[bank]  = nil };
      if (loopPlaySynths[bank].notNil) { loopPlaySynths[bank].free; loopPlaySynths[bank] = nil };
      bufs[bank].zero;
    });

    // Threshold detector ───────────────────────────────────────────────────────────────────────
    this.addCommand("thresh_start", "f", { arg msg;
      if (threshSynth.notNil) { threshSynth.free };
      threshSynth = Synth(\ooze_thresh, [\thresh, msg[1].asFloat], context.xg);
    });

    this.addCommand("thresh_stop", "", { arg msg;
      if (threshSynth.notNil) { threshSynth.free; threshSynth = nil };
    });

    // Disk I/O ─────────────────────────────────────────────────────────────────────────────────
    this.addCommand("save", "is", { arg msg;
      bufs[msg[1].asInteger.clip(0, numBanks - 1)].write(msg[2].asString, "wav", "int16");
    });

    this.addCommand("load", "is", { arg msg;
      bufs[msg[1].asInteger.clip(0, numBanks - 1)].read(msg[2].asString);
    });

    // Sine drone controls ──────────────────────────────────────────────────────────────────────
    this.addCommand("sine_hz",    "if", { arg msg; sineSynths[msg[1].asInteger.clip(0,3)].set(\hz,       msg[2].asFloat) });
    this.addCommand("sine_vol",   "if", { arg msg; sineSynths[msg[1].asInteger.clip(0,3)].set(\vol,      msg[2].asFloat) });
    this.addCommand("sine_pan",   "if", { arg msg; sineSynths[msg[1].asInteger.clip(0,3)].set(\pan,      msg[2].asFloat) });
    this.addCommand("sine_fm",    "if", { arg msg; sineSynths[msg[1].asInteger.clip(0,3)].set(\fm_index, msg[2].asFloat) });
    this.addCommand("sine_ratio", "if", { arg msg; sineSynths[msg[1].asInteger.clip(0,3)].set(\fm_ratio, msg[2].asFloat) });

    // Glut granular playback ───────────────────────────────────────────────────────────────────
    // args: bank, pos, speed, size, density, pitch, pan, spread, amp, rev_mix
    this.addCommand("play_glut", "ifffffffff", { arg msg;
      var bank = msg[1].asInteger.clip(0, numBanks - 1);
      Synth(\ooze_glut, [
        \buf,     bufs[bank].bufnum,
        \out,     context.out_b.index,
        \pos,     msg[2].asFloat,
        \speed,   msg[3].asFloat,
        \size,    msg[4].asFloat,
        \density, msg[5].asFloat,
        \pitch,   msg[6].asFloat,
        \pan,     msg[7].asFloat,
        \spread,  msg[8].asFloat,
        \amp,     msg[9].asFloat,
        \rev_mix, msg[10].asFloat
      ], context.xg);
    });
  }

  free {
    recSynths.do      { |s| if (s.notNil) { s.free } };
    loopPlaySynths.do { |s| if (s.notNil) { s.free } };
    loopRecSynths.do  { |s| if (s.notNil) { s.free } };
    if (threshSynth.notNil) { threshSynth.free };
    sineSynths.do     { |s| if (s.notNil) { s.free } };
    bufs.do { |b| b.free };
  }
}
