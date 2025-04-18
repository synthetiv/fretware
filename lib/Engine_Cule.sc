Engine_Cule : CroneEngine {

	classvar nVoices = 3;
	classvar nRecordedModulators = 6;
	classvar bufferRateScale = 0.5;
	classvar maxLoopTime = 60;

	var controlDef;

	var opTypeDefNames;
	var modulationDestNames;
	var controlRateDestNames;
	var modulationSourceNames;
	var controlRateSourceNames;
	var patchArgs;
	var selectedVoiceArgs;

	var fmRatios;
	var fmRatiosInterleaved;
	var fmIntervals;
	var nRatios;

	var d50Resources;
	var sq80Resources;

	var baseFreqBus;
	var voiceBuses;
	var voiceOpStates;
	var voiceSynths;
	var patchBuses;
	var replySynth;
	var polls;
	var opFadeReplyFunc;
	var opTypeReplyFunc;
	var fxTypeReplyFunc;
	var lfoTypeReplyFunc;
	var voiceAmpReplyFunc;
	var voicePitchReplyFunc;
	var lfoGateReplyFunc;

	var selectedVoice = 0;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	// helper function / pseudo-UGen: an FM operator that can crossfade its tuning across a set
	// of predefined ratios
	harmonicOsc {
		arg uGen, hz, harmonic, uGenArg;
		var whichRatio = harmonic.linlin(-1, 1, 0, nRatios - 1);
		var whichOsc = (Fold.kr(whichRatio).linlin(0, 1, -1, 1) * 1.25).clip2;
		^LinXFade2.ar(
			uGen.ar(hz * Select.kr(whichRatio + 1 / 2, fmRatiosInterleaved[0]), uGenArg),
			uGen.ar(hz * Select.kr(whichRatio / 2, fmRatiosInterleaved[1]), uGenArg),
			whichOsc
		);
	}

	buildRomplerDefs {
		arg prefix, baseFreq, path, waveParamsArray, waveMapsLoopArray, waveMapsOneShotArray;

		// start, end, and pitch offset from baseFreq
		var waveParamsWithPitchesCalculated = waveParamsArray.collect({
			arg params;
			var pitchAdjusted = [ params[0], params[1], (params[2] - (params[3] / 128)).midiratio ];
			pitchAdjusted.postln;
			pitchAdjusted;
		});
		var waveParams = Buffer.loadCollection(context.server, waveParamsWithPitchesCalculated.flatten, 3);
		var waveMapsLoop = Buffer.loadCollection(context.server, waveMapsLoopArray.flatten, 16);
		var waveMapsOneShot = Buffer.loadCollection(context.server, waveMapsOneShotArray.flatten, 16);
		var sampleData = Buffer.read(context.server, path, 0, -1);

		// Looping sample player
		SynthDef.new(prefix.asString ++ "Loop", {
			var whichRatio = \ratio.kr.linlin(-1, 1, 0, nRatios);
			var pitch = \pitch.kr + Select.kr(whichRatio, fmIntervals);
			var rate = 2.pow(pitch) * In.kr(baseFreqBus) / baseFreq;
			// TODO: the use of 'index' here means sample choice is modulated by amp by default,
			// which usually doesn't sound great, and is confusing. use \ratio instead??
			// and index could control... uhhhhhhhhhh... saturation... tone... something
			// -- something such as phase modulation... or sync or something
			var whichMap = \index.ar.linlin(-1, 1, 0, waveMapsLoopArray.size - 0.5).trunc;
			var whichRange = pitch.linlin(-1/24, 23/24, 9, 10.5, nil);
			var whichWave = Select.ar(whichRange, BufRd.ar(16, waveMapsLoop, whichMap, interpolation: 1));
			var duckTime = 0.005;
			var waveChanged = Trig.ar(Changed.ar(whichWave) + Impulse.ar(0), duckTime);
			var duckEnv = Env.new([1, 0, 0, 1], [duckTime, SampleDur.ir, duckTime]).ar(gate: waveChanged);
			var delayedTrig = TDelay.ar(waveChanged, duckTime);
			var params = Latch.ar(
				BufRd.ar(3, waveParams, whichWave, interpolation: 1),
				delayedTrig
			);
			var phase = Phasor.ar(delayedTrig, rate * params[2], params[0], params[1], params[0]);
			Out.ar(\outBus.ir, BufRd.ar(1, sampleData, phase, 0, 4) * duckEnv);
		}).add;

		// One-shot sample player
		SynthDef.new(prefix.asString ++ "OneShot", {
			var whichRatio = \ratio.kr.linlin(-1, 1, 0, nRatios);
			var pitch = \pitch.kr + Select.kr(whichRatio, fmIntervals);
			var rate = 2.pow(pitch) * In.kr(baseFreqBus) / baseFreq;
			var whichMap = \index.ar.linlin(-1, 1, 0, waveMapsOneShotArray.size - 0.5).trunc;
			var whichRange = pitch.linlin(0, 1, 9, 10.5, nil);
			var whichWave = Select.ar(whichRange, BufRd.ar(16, waveMapsOneShot, whichMap, interpolation: 1));
			// retrigger on sample change
			var duckTime = 0.003;
			var trig = Trig.ar(\trig.tr, duckTime); // don't retrigger DURING a duck
			var duckEnv = Env.new([1, 0, 0, 1], [duckTime, SampleDur.ir, duckTime]).ar(gate: trig);
			var delayedTrig = TDelay.ar(trig, duckTime);
			var params = Latch.ar(
				BufRd.ar(3, waveParams, whichWave, interpolation: 1),
				delayedTrig
			);
			var phase = (params[0] + Sweep.ar(delayedTrig, rate * SampleRate.ir * params[2]));
			Out.ar(\outBus.ir, BufRd.ar(1, sampleData, phase.min(params[1]), 0, 4) * duckEnv);
		}).add;

		// return buffers so we can free them later
		[ waveParams, waveMapsLoop, waveMapsOneShot, sampleData ];
	}

	swapOp {
		arg v, op; // op A = 0, B = 1
		var opState = voiceOpStates[v][op];
		var defNames = opTypeDefNames[opState[\type]];
		var defName = if(defNames.class === Array, { defNames[opState[\fade]] }, defNames);
		var buses = voiceBuses[v];
		var synths = voiceSynths[v];
		var thisBus = Bus.newFrom(buses[\opAudio], op);
		var thatBus = Bus.newFrom(buses[\opAudio], 1 - op);
		var newOp = Synth.replace(synths[op + 1], defName, [
			\inBus, thatBus,
			\outBus, thisBus
		]);
		newOp.map(\pitch, Bus.newFrom(buses[\opPitch], op));
		newOp.map(\ratio, Bus.newFrom(buses[\opRatio], op));
		newOp.map(\index, Bus.newFrom(buses[\opIndex], op));
		newOp.map(\trig, buses[\trig]);
		synths.put(op + 1, newOp);
	}

	swapFx {
		arg v, slot, defName;
		var buses = voiceBuses[v];
		var synths = voiceSynths[v];
		var bus = Bus.newFrom(buses[\mixAudio], 0);
		var newFx = Synth.replace(synths[slot + 4], defName, [
			\bus, bus
		]);
		newFx.map(\intensity, Bus.newFrom(buses[\fx], slot));
		synths[0].set([ \fxASynth, \fxBSynth ].at(slot), newFx);
		synths.put(slot + 4, newFx);
	}

	swapLfo {
		arg v, slot, defName;
		var buses = voiceBuses[v];
		var synths = voiceSynths[v];
		var newLfo = Synth.replace(synths[slot + 6], defName, [
			\stateBus, Bus.newFrom(buses[\lfoState], slot),
			\voiceIndex, v,
			\lfoIndex, slot
		]);
		newLfo.map(\freq, Bus.newFrom(buses[\lfoFreq], slot));
		synths.put(slot + 6, newLfo);
	}

	alloc {

		opTypeDefNames = [
			[ \operatorFM, \operatorFMFade ],
			[ \operatorFB, \operatorFBFade ],
			[ \operatorSQ80Loop, \operatorSQ80OneShot ],
			[ \operatorSquare, \operatorSquareFade ],
			[ \operatorSaw, \operatorSawFade ],
			\operatorKarp,
			\operatorComb,
			\operatorCombExt,
			\operatorFMD,
			\nothing
		];

		// TODO: reorganize this stuff. dry it out. 'pan' should be "declared" with rate = control,
		// scope = voice (as opposed to patch)... and so on.

		// modulatable parameters for audio synths
		modulationDestNames = [
			\amp,
			\pan,
			\ratioA,
			\detuneA, // TODO: maybe detune can be control rate... then op pitch buses can be control
			// rate... and maybe that would save CPU
			\indexA,
			\ratioB,
			\detuneB,
			\indexB,
			\opMix,
			\fxA,
			\fxB,
			\hpCutoff,
			\lpCutoff,
			\attack,
			\release,
			\lfoAFreq,
			\lfoBFreq,
			\lfoCFreq,
		];

		controlRateDestNames = [
			\pan,
			\ratioA,
			\ratioB,
			\opMix,
			\fxA,
			\fxB,
			\attack,
			\release,
			\lfoAFreq,
			\lfoBFreq,
			\lfoCFreq
		];

		// modulation sources
		modulationSourceNames = [
			\amp,
			\hand,
			\eg,
			\eg2,
			\lfoA,
			\lfoB,
			\lfoC,
			\sh
		];

		controlRateSourceNames = [
			\hand,
			\lfoA,
			\lfoB,
			\lfoC,
			\sh
		];

		// modulatable AND non-modulatable parameters
		patchArgs = [
			\pitchSlew,
			\hpRQ,
			\lpRQ,
			\opFadeA,
			\opTypeA,
			\opFadeB,
			\opTypeB,
			\fxTypeA,
			\fxTypeB,
			\egType,
			\eg2Time,
			\ampMode,
			\lfoTypeA,
			\lfoTypeB,
			\lfoTypeC,
			modulationDestNames.difference([ \pan ]),
			Array.fill(modulationSourceNames.size, { |s|
				Array.fill(modulationDestNames.size, { |d|
					(modulationSourceNames[s] ++ '_' ++ modulationDestNames[d]).asSymbol;
				});
			}).flatten;
		].flatten;

		// frequency ratios used by the two FM operators of each voice
		// declared as one array, but stored as two arrays, one with odd and one with even
		// members of the original; this allows operators to crossfade between two ratios
		// (see harmonicOsc function)
		fmRatios = [1/128, 1/64, 1/32, 1/16, 1/8, 1/4, 1/2,
			1, 2, /* 3, */ 4, /* 5, */ 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];
		fmRatiosInterleaved = fmRatios.clump(2).flop;
		fmIntervals = fmRatios.ratiomidi / 12;
		nRatios = fmRatios.size;

		baseFreqBus = Bus.control(context.server);

		voiceBuses = Array.fill(nVoices, {
			Dictionary[
				\amp -> Bus.audio(context.server),
				\eg -> Bus.audio(context.server, 2),
				\trig -> Bus.control(context.server),
				\hand -> Bus.control(context.server),
				\pan -> Bus.control(context.server),
				\pitch -> Bus.control(context.server),
				\opPitch -> Bus.audio(context.server, 2),
				\opRatio -> Bus.control(context.server, 2),
				\opFadeSize -> Bus.control(context.server, 2),
				\opIndex -> Bus.audio(context.server, 2),
				\opMix -> Bus.control(context.server),
				\opAudio -> Bus.audio(context.server, 2),
				\mixAudio -> Bus.audio(context.server),
				\fx -> Bus.control(context.server, 2),
				\cutoff -> Bus.audio(context.server, 2),
				\rq -> Bus.control(context.server, 2),
				\lfoFreq -> Bus.control(context.server, 3),
				\lfoState -> Bus.control(context.server, 3),
				\outLevel -> Bus.control(context.server)
			];
		});

		controlDef = SynthDef.new(\voiceControls, {

			arg pitch = 0,
				gate = 0,
				tip = 0,
				palm = 0,
				freeze = 0,
				t_loopReset = 0,
				loopLength = 0.3,
				loopPosition = 0,
				loopRateScale = 1,
				attack = 0.01,
				release = 0.3;

			var modulators,
				bufferRate, bufferLength, bufferPhase, buffer,
				loopStart, loopPhase, loopTrigger, loopOffset,
				modulation = Dictionary.new,
				lag = 0.01,
				fxA, fxB,
				recPitch, recTip, recHand, recGate, recTrig,
				trig, ampMode, hand, freezeWithoutGate, eg, eg2, amp;

			// send signals to sclang to handle op, fx, and lfo type changes
			var voiceIndex = \voiceIndex.ir;
			Dictionary[
				\opFade -> [ \opFadeA, \opFadeB ],
				\opType -> [ \opTypeA, \opTypeB ],
				\fxType -> [ \fxTypeA, \fxTypeB ],
				\lfoType -> [ \lfoTypeA, \lfoTypeB, \lfoTypeC ]
			].keysValuesDo({ |typeName, controlNames|
				var path = '/' ++ typeName;
				controlNames.do({ |controlName, i|
					var value = NamedControl.kr(controlName);
					// TODO: use voiceIndex as replyID, NOT first value. same for the other SendReplys.
					SendReply.kr(Changed.kr(value), path, [ voiceIndex, i, value ]);
				});
			});

			// create buffer for looping pitch/amp/control data
			bufferRate = ControlRate.ir * bufferRateScale;
			bufferLength = context.server.sampleRate / context.server.options.blockSize * maxLoopTime * bufferRateScale;
			bufferPhase = Phasor.kr(rate: bufferRateScale * (1 - freeze), end: bufferLength);
			buffer = LocalBuf.new(bufferLength, nRecordedModulators);
			loopStart = bufferPhase - (loopLength * bufferRate).min(bufferLength);
			loopPhase = Phasor.kr(Trig.kr(freeze) + t_loopReset, bufferRateScale * loopRateScale, loopStart, bufferPhase, loopStart);
			// TODO: confirm that this is really firing when it's supposed to (i.e. when loopPhase
			// resets)! if not, either fix it, or do away with it
			loopTrigger = Trig.kr(BinaryOpUGen.new('==', loopPhase, loopStart));
			loopOffset = Latch.kr(bufferLength - (loopLength * bufferRate), loopTrigger) * loopPosition;
			loopPhase = loopPhase - loopOffset;
			trig = Trig.kr(\trig.tr, 0.01);
			hand = tip - palm;
			BufWr.kr([pitch, tip, hand, gate, trig], buffer, bufferPhase);
			// read values from recorded loop (if any)
			# recPitch, recTip, recHand, recGate, recTrig = BufRd.kr(nRecordedModulators, buffer, loopPhase, interpolation: 1);
			// new pitch values can "punch through" frozen ones when gate is high
			freezeWithoutGate = freeze.min(1 - gate);
			pitch = Select.kr(freezeWithoutGate, [ pitch, recPitch ]);
			// punch tip through too, only when gate is high
			tip = Select.kr(freezeWithoutGate, [ tip, recTip ]);
			// mix incoming hand data with recorded hand (fade in when freeze is engaged)
			hand = hand + (Linen.kr(freeze, 0.3, 1, 0) * recHand);
			// combine incoming gates with recorded gates
			gate = gate.max(freeze * recGate);
			trig = trig.max(freeze * recTrig);

			// calculate modulation matrix

			// this feedback loop is needed in order for modulators to modulate one another
			amp = InFeedback.ar(\ampBus.ir);
			modulators = [
				amp,
				In.kr(\handBus.ir),
				InFeedback.ar(\egBus.ir, 2),
				In.kr(\lfoStateBus.ir, 3),
				Latch.kr(WhiteNoise.kr, Trig.kr(gate) + Trig.kr(amp > 0.01))
			].flatten;

			// TODO: make a 'patch' synth that smooths out all patch params (that need smoothing) ONCE, so
			// each voice doesn't need to do that individually.
			// patch synth would also have args for lfo types, etc.
			// then voices could SendReply when type args change, which would trigger swapLfo etc.

			// build a dictionary of summed modulation signals to apply to parameters
			modulationDestNames.do({ |destName|
				if(controlRateDestNames.includes(destName), {
					// control-rate destinations
					modulation.put(destName, Mix.fill(modulationSourceNames.size, { |m|
						var sourceName = modulationSourceNames[m];
						var modulator = if(controlRateSourceNames.includes(sourceName).not, {
							A2K.kr(modulators[m]);
						}, {
							modulators[m];
						});
						modulator * NamedControl.kr((sourceName ++ '_' ++ destName).asSymbol);
					}).lag(lag)); // no need to smooth all routing factors separately.
				}, {
					// audio-rate destinations
					modulation.put(destName, Mix.fill(modulationSourceNames.size, { |m|
						var sourceName = modulationSourceNames[m];
						var modulator = if(controlRateSourceNames.includes(sourceName), {
							K2A.ar(modulators[m]);
						}, {
							modulators[m];
						});
						// amp modulates index and cutoff differently: it always lowers the parameter, never
						// increases it. this way, default routing can include amp->index, but if index is set to
						// minimum, we'll always hear a sine wave.
						// amp ranges from 0 to 1, and amount from -1 to 1.
						// when amount is positive, low amp values lower index/cutoff. when amount is negative,
						// high amp values lower the index/cutoff.
						// in both cases, amp is scaled so that maximum reduction is 2.
						// except for HP cutoff, which works the opposite way: it is only ever raised.
						if(\amp === sourceName && [\indexA, \indexB, \hpCutoff, \lpCutoff].includes(destName), {
							var amount = NamedControl.kr(('amp_' ++ destName).asSymbol, lags: lag);
							var polaritySwitch = BinaryOpUGen(if(\hpCutoff === sourceName, '<', '>'), amount, 0);
							(modulator - polaritySwitch) * 2 * amount;
						}, {
							modulator * NamedControl.kr((sourceName ++ '_' ++ destName).asSymbol, lags: lag);
						});
					}));
				});
			});

			attack = attack * 8.pow(modulation[\attack]);
			release = release * 8.pow(modulation[\release]);
			eg = Select.ar(\egType.kr(1), [
				// ASR, linear attack
				Env.new(
					[0, 1, 0],
					[attack, release],
					[0, -6],
					releaseNode: 1
				).ar(gate: gate),
				// AR, Maths-style symmetrical attack
				Env.new(
					[0, 1, 0],
					[attack, release],
					[6, -6]
				).ar(gate: trig)
			]);
			eg2 = Env.perc(0.001, \eg2Time.kr(1) + attack + release, curve: -8).ar(gate: trig);

			Out.kr(\opRatioBus.ir, [
				\ratioA.kr.lag(0.1) + modulation[\ratioA],
				\ratioB.kr.lag(0.1) + modulation[\ratioB]
			]);

			Out.ar(\opIndexBus.ir, [
				\indexA.ar.lag(0.1) + modulation[\indexA],
				\indexB.ar.lag(0.1) + modulation[\indexB]
			]);

			Out.kr(\opMixBus.ir, \opMix.kr.lag(0.1) + modulation[\opMix]);

			fxA = \fxA.kr.lag(0.1) + modulation[\fxA];
			fxB = \fxB.kr.lag(0.1) + modulation[\fxB];
			Out.kr(\fxBus.ir, [ fxA, fxB ]);
			Pause.kr(fxA > -1, \fxASynth.kr);
			Pause.kr(fxB > -1, \fxBSynth.kr);

			Out.ar(\cutoffBus.ir, [
				\hpCutoff.ar.lag(0.1) + modulation[\hpCutoff],
				\lpCutoff.ar.lag(0.1) + modulation[\lpCutoff]
			]);

			Out.kr(\rqBus.ir, [
				\hpRQ.kr(0.7),
				\lpRQ.kr(0.7)
			]);

			Out.kr(\lfoFreqBus.ir, [
				\lfoAFreq.kr(1) * 8.pow(modulation[\lfoAFreq]),
				\lfoBFreq.kr(1) * 8.pow(modulation[\lfoBFreq]),
				\lfoCFreq.kr(1) * 8.pow(modulation[\lfoCFreq])
			]);

			// slew tip for direct control of amplitude -- otherwise there will be audible steppiness
			tip = Lag.ar(K2A.ar(tip), 0.05);
			// amp mode shouldn't change while frozen
			ampMode = Gate.kr(\ampMode.kr, 1 - freeze);
			amp = Select.ar(K2A.ar(ampMode), [
				tip,
				tip * eg,
				eg * -6.dbamp
			]);
			amp = amp * (1 + modulation[\amp]);
			amp = amp.clip(0, 1);

			Out.ar(\ampBus.ir, amp);
			Out.ar(\egBus.ir, [ eg, eg2 ]);
			Out.kr(\handBus.ir, hand);

			Out.kr(\panBus.ir, \pan.kr.lag(0.1) + modulation[\pan]);

			pitch = pitch + \shift.kr;

			// TODO: why can't I use MovingAverage.kr here to get a linear slew?!
			// if I try that, SC seems to just hang forever, no error message
			pitch = Lag.kr(pitch, \pitchSlew.kr);
			Out.kr(\pitchBus.ir, pitch);

			Out.ar(\opPitchBus.ir, [
				\detuneA.ar.cubed.lag(0.1) + modulation[\detuneA],
				\detuneB.ar.cubed.lag(0.1) + modulation[\detuneB]
			] * 1.17 + pitch);
			// max detune of 1.17 octaves is slightly larger than a ratio of 9/4

			Out.kr(\trigBus.ir, trig);

			Out.kr(\outLevelBus.ir, \outLevel.kr(0.2));
		}).add;

		// Triangle LFO
		SynthDef.new(\lfoTri, {
			var lfo = LFTri.kr(\freq.kr(1), 4.rand);
			var gate = lfo > 0;
			Out.kr(\stateBus.ir, lfo);
			SendReply.kr(Changed.kr(gate), '/lfoGate', [\voiceIndex.ir, \lfoIndex.ir, gate]);
		}).add;

		// Random step LFO
		SynthDef.new(\lfoSH, {
			var gate = LFPulse.kr(\freq.kr(1), 1.rand);
			Out.kr(\stateBus.ir, Lag.kr(TRand.kr(-1, 1, gate), 0.01));
			SendReply.kr(Changed.kr(gate), '/lfoGate', [\voiceIndex.ir, \lfoIndex.ir, gate]);
		}).add;

		// Random Dust step LFO
		SynthDef.new(\lfoDust, {
			var freq = \freq.kr(1);
			var trig = Dust.kr(freq);
			var gate = Trig.kr(trig, (freq * 8).reciprocal);
			Out.kr(\stateBus.ir, Lag.kr(TRand.kr(-1, 1, trig), 0.01));
			SendReply.kr(Changed.kr(gate), '/lfoGate', [\voiceIndex.ir, \lfoIndex.ir, gate]);
		}).add;

		// Smooth random LFO
		SynthDef.new(\lfoDrift, {
			var freq = \freq.kr(1);
			var lfo = LFDNoise1.kr(LFNoise0.kr(freq * 0.5).linlin(0, 1, freq * 0.5, freq * 2));
			var gate = lfo > 0;
			Out.kr(\stateBus.ir, lfo);
			SendReply.kr(Changed.kr(gate), '/lfoGate', [\voiceIndex.ir, \lfoIndex.ir, gate]);
		}).add;

		// Ramp LFO
		SynthDef.new(\lfoRamp, {
			var lfo = LFSaw.kr(\freq.kr(1), 4.rand);
			var gate = lfo < 0;
			Out.kr(\stateBus.ir, Lag.kr(lfo, 0.01));
			SendReply.kr(Changed.kr(gate), '/lfoGate', [\voiceIndex.ir, \lfoIndex.ir, gate]);
		}).add;

		// Self-FM operator
		SynthDef.new(\operatorFB, {
			var hz = 2.pow(\pitch.kr) * In.kr(baseFreqBus);
			var whichRatio = \ratio.kr.linlin(-1, 1, 0, nRatios);
			var output = SinOscFB.ar(
				hz * Select.kr(whichRatio, fmRatios),
				\index.ar(-1).lincurve(-1, 1, 0, 1.3pi, 3, \min)
			);
			Out.ar(\outBus.ir, output);
		}).add;

		// Self-FM operator with crossfading between ratios
		SynthDef.new(\operatorFBFade, {
			var hz = 2.pow(\pitch.kr) * In.kr(baseFreqBus);
			var output = this.harmonicOsc(
				SinOscFB,
				hz,
				\ratio.kr,
				\index.ar(-1).lincurve(-1, 1, 0, 1.3pi, 3, \min)
			);
			Out.ar(\outBus.ir, output);
		}).add;

		// External-FM operator
		SynthDef.new(\operatorFM, {
			var pitch = \pitch.kr;
			var hz = 2.pow(pitch) * In.kr(baseFreqBus);
			var whichRatio = \ratio.kr.linlin(-1, 1, 0, nRatios);
			var output = SinOsc.ar(
				hz * Select.kr(whichRatio, fmRatios),
				(InFeedback.ar(\inBus.ir) * \index.ar(-1).lincurve(-1, 1, 0, 13pi, 4, \min) * 0.7.pow(pitch)).mod(2pi)
			);
			Out.ar(\outBus.ir, output);
		}).add;

		// External-FM operator with crossfading between ratios
		SynthDef.new(\operatorFMFade, {
			var pitch = \pitch.kr;
			var hz = 2.pow(pitch) * In.kr(baseFreqBus);
			var output = this.harmonicOsc(
				SinOsc,
				hz,
				\ratio.kr,
				(InFeedback.ar(\inBus.ir) * \index.ar(-1).lincurve(-1, 1, 0, 13pi, 4, \min) * 0.7.pow(pitch)).mod(2pi)
			);
			Out.ar(\outBus.ir, output);
		}).add;

		// External-FM operator with a tuned delay at its FM input
		SynthDef.new(\operatorFMD, {
			var pitch = \pitch.kr;
			var whichRatio = \ratio.kr.linlin(-1, 1, 0, nRatios);
			var hz = 2.pow(pitch) * In.kr(baseFreqBus);
			// we'll delay the input signal by the shortest possible amount of time
			// that is (a) greater than block size, and (b) an octave multiple of
			// the oscillator pitch
			var delaySafeHz = (hz / ControlRate.ir).ratiomidi.wrap(-12, 0).midiratio * ControlRate.ir;
			var delayTime = K2A.ar(delaySafeHz.reciprocal);
			var delayDelayBuf = LocalBuf.new(SampleRate.ir * 2);
			var delayedDelayTime = BufDelayN.ar(delayDelayBuf, delayTime, delayTime); // haha lol
			var delta = delayedDelayTime - delayTime;
			var deltaOrInf = Select.ar(delta, [DC.ar(inf), delta]);
			var slewedDelayTime = Slew.ar(
				delayTime,
				1 - 0.5.pow(deltaOrInf),
				2.pow(deltaOrInf) - 1
			);
			var delayBuf = LocalBuf.new(SampleRate.ir * 2);
			var delayedIn = BufDelayC.ar(
				delayBuf,
				InFeedback.ar(\inBus.ir),
				slewedDelayTime - (BlockSize.ir * SampleDur.ir)
			);
			var output = SinOsc.ar(
				hz * Select.kr(whichRatio, fmRatios),
				(delayedIn * \index.ar(-1).lincurve(-1, 1, 0, 13pi, 4, \min) * 0.7.pow(pitch)).mod(2pi)
			);
			Out.ar(\outBus.ir, output);
		}).add;

		// Karplus-Strong oscillator
		SynthDef.new(\operatorKarp, {
			var whichRatio = \ratio.kr.linlin(-1, 1, 0, nRatios);
			var hz = 2.pow(\pitch.kr) * In.kr(baseFreqBus) * Select.kr(whichRatio, fmRatios);
			var delayTime = K2A.ar(hz.reciprocal);
			var delayDelayBuf = LocalBuf.new(SampleRate.ir * 2);
			var delayedDelayTime = BufDelayN.ar(delayDelayBuf, delayTime, delayTime); // haha lol
			var delta = delayedDelayTime - delayTime;
			var deltaOrInf = Select.ar(delta, [DC.ar(inf), delta]);
			var slewedDelayTime = Slew.ar(
				delayTime,
				1 - 0.5.pow(deltaOrInf),
				2.pow(deltaOrInf) - 1
			);
			// excitation signal is a mix of noise and a "sine wave chirp", h/t Nathan Ho
			var trigEnv = Env.perc(0.001, 0.01).ar(gate: \trig.kr);
			var chirp = SinOsc.ar(trigEnv.linexp(0, 1, 20, 16000));
			var noise = WhiteNoise.ar(trigEnv);
			var decay = \index.ar(-1).linexp(-1, 1, -0.1, -32);
			var damping = hz.explin(20, 2000, 0.6, 0);
			var output = chirp * trigEnv + noise + Pluck.ar(chirp + noise, \trig.kr, 2, slewedDelayTime, decay, damping);
			Out.ar(\outBus.ir, output);
		}).add;

		// Comb filter
		SynthDef.new(\operatorComb, {
			var whichRatio = \ratio.kr.linlin(-1, 1, 0, nRatios);
			var hz = 2.pow(\pitch.kr) * In.kr(baseFreqBus) * Select.kr(whichRatio, fmRatios);
			// when desired pitch is higher than control rate, find the highest octave
			// DOWN from that pitch that will result in a delay time greater than the
			// block size.
			var delaySafeHz = hz.min((hz / ControlRate.ir).ratiomidi.wrap(-12, 0).midiratio * ControlRate.ir);
			var delayTime = K2A.ar(delaySafeHz.reciprocal);
			var delayDelayBuf = LocalBuf.new(SampleRate.ir * 2);
			var delayedDelayTime = BufDelayN.ar(delayDelayBuf, delayTime, delayTime); // haha lol
			var delta = delayedDelayTime - delayTime;
			var deltaOrInf = Select.ar(delta, [DC.ar(inf), delta]);
			var slewedDelayTime = Slew.ar(
				delayTime,
				1 - 0.5.pow(deltaOrInf),
				2.pow(deltaOrInf) - 1
			);
			var decayFactor = -60.dbamp.pow(slewedDelayTime / \index.ar(-1).lincurve(-1, 1, 0, 8, 8)).neg;
			var delayBuf = LocalBuf.new(SampleRate.ir * 2);
			var delayedIn = BufDelayC.ar(
				delayBuf,
				(LocalIn.ar * decayFactor).tanh + InFeedback.ar(\inBus.ir),
				slewedDelayTime - (BlockSize.ir * SampleDur.ir)
			);
			LocalOut.ar(delayedIn);
			Out.ar(\outBus.ir, delayedIn);
		}).add;

		// Comb with external audio input
		SynthDef.new(\operatorCombExt, {
			var whichRatio = \ratio.kr.linlin(-1, 1, 0, nRatios);
			var hz = 2.pow(\pitch.kr) * In.kr(baseFreqBus) * Select.kr(whichRatio, fmRatios);
			// when desired pitch is higher than control rate, find the highest octave
			// DOWN from that pitch that will result in a delay time greater than the
			// block size.
			var delaySafeHz = hz.min((hz / ControlRate.ir).ratiomidi.wrap(-12, 0).midiratio * ControlRate.ir);
			var delayTime = K2A.ar(delaySafeHz.reciprocal);
			var delayDelayBuf = LocalBuf.new(SampleRate.ir * 2);
			var delayedDelayTime = BufDelayN.ar(delayDelayBuf, delayTime, delayTime); // haha lol
			var delta = delayedDelayTime - delayTime;
			var deltaOrInf = Select.ar(delta, [DC.ar(inf), delta]);
			var slewedDelayTime = Slew.ar(
				delayTime,
				1 - 0.5.pow(deltaOrInf),
				2.pow(deltaOrInf) - 1
			);
			var decayFactor = -60.dbamp.pow(slewedDelayTime / \index.ar(-1).lincurve(-1, 1, 0, 8, 8)).neg;
			var delayBuf = LocalBuf.new(SampleRate.ir * 2);
			var delayedIn = BufDelayC.ar(
				delayBuf,
				(LocalIn.ar * decayFactor).tanh + SoundIn.ar,
				slewedDelayTime - (BlockSize.ir * SampleDur.ir)
			);
			LocalOut.ar(delayedIn);
			Out.ar(\outBus.ir, delayedIn);
		}).add;

		// Band-limited pseudo-analog oscillator, square-saw mix
		SynthDef.new(\operatorSquare, {
			var whichRatio = \ratio.kr.linlin(-1, 1, 0, nRatios);
			var hz = 2.pow(\pitch.kr) * In.kr(baseFreqBus) * Select.kr(whichRatio, fmRatios);
			var output = LinSelectX.ar(\index.ar(-1).linlin(-1, 1, 0, 1), [
				BlitB3Square.ar(hz),
				BlitB3Saw.ar(hz * 2)
			]);
			Out.ar(\outBus.ir, output * 6.dbamp);
		}).add;

		// Band-limited pseudo-analog oscillator, all square with fades between ratios and variable leak
		SynthDef.new(\operatorSquareFade, {
			var hz = 2.pow(\pitch.kr) * In.kr(baseFreqBus);
			var output = this.harmonicOsc(
				BlitB3Square,
				hz,
				\ratio.kr,
				\index.ar(-1).lincurve(-1, 1, 0.99, 0, 3)
			);
			Out.ar(\outBus.ir, output * 6.dbamp);
		}).add;

		// Band-limited pseudo-analog oscillator, square-saw mix
		SynthDef.new(\operatorSaw, {
			var whichRatio = \ratio.kr.linlin(-1, 1, 0, nRatios);
			var hz = 2.pow(\pitch.kr) * In.kr(baseFreqBus) * Select.kr(whichRatio, fmRatios);
			var output = LinSelectX.ar(\index.ar(-1).linlin(-1, 1, 0, 1), [
				BlitB3Saw.ar(hz),
				BlitB3Square.ar(hz / 2)
			]);
			Out.ar(\outBus.ir, output * 6.dbamp);
		}).add;

		// Band-limited pseudo-analog oscillator, all saw with fades between ratios and variable leak
		SynthDef.new(\operatorSawFade, {
			var hz = 2.pow(\pitch.kr) * In.kr(baseFreqBus);
			var output = this.harmonicOsc(
				BlitB3Saw,
				hz * 2,
				\ratio.kr,
				\index.ar(-1).lincurve(-1, 1, 0.99, 0, 3)
			);
			Out.ar(\outBus.ir, output * 6.dbamp);
		}).add;

		sq80Resources = this.buildRomplerDefs(
			\operatorSQ80,
			// these samples are (around?) 1024 samples per cycle.
			48000 / 1024,
			"/home/we/dust/data/fretware/sq80v2.wav",
			CSVFileReader.read("/home/we/dust/code/fretware/data/sq80-params.csv").asFloat,
			CSVFileReader.read("/home/we/dust/code/fretware/data/sq80-maps-loop.csv").asFloat,
			CSVFileReader.read("/home/we/dust/code/fretware/data/sq80-maps-oneshot.csv").asFloat
		);

		// d50Resources = this.buildRomplerDefs(
		// 	\operatorD50,
		// 	// looped slices are 2048 samples long, with 32 cycles per slice
		// 	// meaning 64 samples = 1 cycle
		// 	48000 / 64 / 2,
		// 	"/home/we/dust/data/fretware/d50.wav",
		// 	[
		// 		188417, 190465, 192513, 194561, 196609, 198657, 200705, 202753,
		// 		204801, 206849, 208897, 210945, 212993, 215041, 217089, 219137,
		// 		221185, 223233, 225281, 227329, 229377, 231425, 233473, 235521,
		// 		237569, 239617, 241665, 243713, 245761, 247809, 249857, 251905,
		// 		253953, 256001, 258049, 260097, nil, // one-shots start here
		// 		731137, 735233, 737281, 909313, 1040503, 1138690, 1202176, 1335304,
		// 		// next one is (kind of??) a one-shot again
		// 		nil, 1531905, 1712129, 1843201,
		// 		// the following start/end points are a little uncertain
		// 		1921025, nil, 2243046, 2408487, nil, 2539521, 2801627, 2985985,
		// 		3063807 // the end
		// 	].dupEach.shift(1).clump(2).reject({
		// 		arg range, index;
		// 		(index == 0) || range.includes(nil);
		// 	}).collect({ |pair| pair - [0, 1] }),
		// 	[
		// 		0, 4097, 8193, 12289, 16385, 24577, 26625, 28673,
		// 		30721, 32769, 34817, 36865, 40961, 45052, /* or maybe 45057 */ 47104, 49153,
		// 		57345, 65537, 73729, 81921, 86017, 90113, 94209, 98305,
		// 		102401, 106497, 110593, 114689, 118785, 122881, 126977, 131073,
		// 		135169, 139265, 143361, 147457, 149505, 151553, 155649, 157697,
		// 		159745, 163841, 167938, 172033, 176129, 180241, 184324, nil, // loops here
		// 		262145, 303107, 368641, 442371, 458754, 491522, 507906, 557058,
		// 		655362, 681988
		// 	].dupEach.shift(1).clump(2).reject({
		// 		arg range, index;
		// 		(index == 0) || range.includes(nil);
		// 	}).collect({ |pair| pair - [0, 1] })
		// );

		SynthDef.new(\operatorMixer, {
			// TODO: pause op synths when they're fully mixed out??
			var opA = In.ar(\opA.ir);
			var opB = In.ar(\opB.ir);
			var output = SelectX.ar(\mix.ar.linlin(-1, 1, 0, 4, nil).wrap(0, 3), [
				opA,
				opB,
				opA * opB * 3.dbamp, // compensate for amplitude loss from sine * sine
				opA
			]);
			Out.ar(\bus.ir, output);
		}).add;

		SynthDef.new(\nothing, {}).add;

		SynthDef.new(\fxSquiz, {
			var bus = \bus.ir;
			ReplaceOut.ar(bus, Squiz.ar(In.ar(bus), \intensity.ar.lincurve(-1, 1, 1, 16, 4, 'min'), 2));
		}).add;

		SynthDef.new(\fxWaveLoss, {
			var bus = \bus.ir;
			ReplaceOut.ar(bus,
				WaveLoss.ar(In.ar(bus), \intensity.ar.lincurve(-1, 1, 0, 127, 4, 'min'), 127, mode: 2)
			);
		}).add;

		SynthDef.new(\fxFold, {
			var bus = \bus.ir;
			ReplaceOut.ar(bus, (In.ar(bus) * \intensity.ar.linexp(-1, 1, 1, 27, 'min')).fold2);
		}).add;

		SynthDef.new(\fxTanh, {
			var bus = \bus.ir;
			ReplaceOut.ar(bus, (In.ar(bus) * \intensity.ar.linexp(-1, 1, 1, 49, 'min')).tanh);
		}).add;

		SynthDef.new(\fxDecimator, {
			var bus = \bus.ir;
			var intensity = \intensity.ar;
			ReplaceOut.ar(bus,
				Decimator.ar(In.ar(bus), intensity.linexp(-1, 1, SampleRate.ir, 1500), intensity.linexp(-1, 1, 14, 1))
			);
		}).add;

		// Dimension C-style chorus
		SynthDef.new(\fxChorus, {
			var bus = \bus.ir;
			var sig = In.ar(bus);
			var intensity = \intensity.ar;
			var lfo = LFTri.kr(intensity.linexp(-1, 1, 0.03, 2, nil)).lag(0.1) * [-1, 1];
			sig = Mix([
				sig,
				// TODO: maybe do DelayC instead
				DelayL.ar(sig, 0.05, lfo * intensity.linexp(-1, 1, 0.0019, 0.005, nil) + [\d1.kr(0.01), \d2.kr(0.007)])
			].flatten);
			ReplaceOut.ar(bus, sig * -6.dbamp);
		}).add;

		// TODO: separate, swappable filter synths

		SynthDef.new(\voiceOutputStage, {

			var hpCutoff, hpRQ,
				lpCutoff, lpRQ;
			var voiceOutput = In.ar(\bus.ir);

			// HPF
			hpCutoff = \hpCutoff.ar(-1).linexp(-1, 1, 4, 24000);
			hpRQ = \hpRQ.kr(0.7);
			hpRQ = hpCutoff.linexp(SampleRate.ir * 0.25 / hpRQ, SampleRate.ir * 0.5, hpRQ, 0.5);
			voiceOutput = RHPF.ar(voiceOutput, hpCutoff, hpRQ);

			// LPF
			lpCutoff = IEnvGen.ar(
				Env.xyc([ [-1, 4], [\lpBreakpointIn.kr(-0.5), \lpBreakpointOut.kr(400), \exp], [1, 24000] ]),
				\lpCutoff.ar(1)
			);
			lpRQ = \lpRQ.kr(0.7);
			lpRQ = lpCutoff.linexp(SampleRate.ir * 0.25 / lpRQ, SampleRate.ir * 0.5, lpRQ, 0.5);
			voiceOutput = RLPF.ar(voiceOutput, lpCutoff, lpRQ);

			// scale by amplitude control value
			voiceOutput = voiceOutput * \amp.ar;

			// scale by output level
			voiceOutput = voiceOutput * Lag.kr(\outLevel.kr, 0.05);

			// pan and write to main outs
			Out.ar(context.out_b, Pan2.ar(voiceOutput, \pan.ar.fold2));
		}).add;

		SynthDef.new(\reply, {
			arg replyRate = 15;
			var replyTrig = Impulse.kr(replyRate);
			nVoices.do({ |v|
				var bus = voiceBuses[v];
				var amp = In.ar(bus[\amp]);
				var pitch = In.kr(bus[\pitch]);
				var trig = In.kr(bus[\trig]);
				var pitchTrig = replyTrig + trig;

				// what's important is peak amplitude, not exact current amplitude at poll time
				amp = Peak.kr(amp, replyTrig);
				SendReply.kr(Peak.kr(Changed.kr(amp), replyTrig) * replyTrig, '/voiceAmp', [v, amp]);

				// respond quickly to triggers, which may change pitch in a meaningful way, even if the change is small
				SendReply.kr(Peak.kr(Changed.kr(pitch), pitchTrig) * pitchTrig, '/voicePitch', [v, pitch, trig]);
			});
		}).add;

		// TODO: master bus FX like saturation, decimation...?

		context.server.sync;

		baseFreqBus.setSynchronous(60.midicps);

		patchBuses = Dictionary.new;
		controlDef.allControlNames.do({
			arg control;
			if(patchArgs.includes(control.name), {
				var bus = Bus.control(context.server);
				bus.set(control.defaultValue);
				patchBuses.put(control.name, bus);
			});
		});

		voiceOpStates = Array.fill(nVoices, {
			Array.fill(2, {
				Dictionary[
					\type -> 0,
					\fade -> 0,
				];
			});
		});

		voiceSynths = Array.fill(nVoices, {
			arg i;

			var controlSynth,
				lfoA, lfoB, lfoC,
				opBBus, opB, opABus, opA,
				mixBus, opMixer, fxB, fxA,
				out;

			var bus = voiceBuses[i];

			controlSynth = Synth.new(\voiceControls, [
				\voiceIndex, i,
				\ampBus, bus[\amp],
				\egBus, bus[\eg],
				\trigBus, bus[\trig],
				\handBus, bus[\hand],
				\panBus, bus[\pan],
				\pitchBus, bus[\pitch],
				\opPitchBus, bus[\opPitch],
				\opRatioBus, bus[\opRatio],
				\opFadeSizeBus, bus[\opFadeSize],
				\opIndexBus, bus[\opIndex],
				\fxBus, bus[\fx],
				\opMixBus, bus[\opMix],
				\cutoffBus, bus[\cutoff],
				\rqBus, bus[\rq],
				\lfoFreqBus, bus[\lfoFreq],
				\lfoStateBus, bus[\lfoState],
				\outLevelBus, bus[\outLevel]
			], context.og, \addToTail); // "output" group
			patchArgs.do({ |name| controlSynth.map(name, patchBuses[name]) });

			lfoA = Synth.new(\lfoTri, [
				\stateBus, Bus.newFrom(bus[\lfoState], 0),
				\voiceIndex, i,
				\lfoIndex, 0
			], context.og, \addToTail);
			lfoA.map(\freq, Bus.newFrom(bus[\lfoFreq], 0));

			lfoB = Synth.new(\lfoTri, [
				\stateBus, Bus.newFrom(bus[\lfoState], 1),
				\voiceIndex, i,
				\lfoIndex, 1
			], context.og, \addToTail);
			lfoB.map(\freq, Bus.newFrom(bus[\lfoFreq], 1));

			lfoC = Synth.new(\lfoTri, [
				\stateBus, Bus.newFrom(bus[\lfoState], 2),
				\voiceIndex, i,
				\lfoIndex, 2
			], context.og, \addToTail);
			lfoC.map(\freq, Bus.newFrom(bus[\lfoFreq], 2));

			opBBus = Bus.newFrom(bus[\opAudio], 1);
			opABus = Bus.newFrom(bus[\opAudio], 0);

			opB = Synth.new(\operatorFB, [
				\inBus, opABus,
				\outBus, opBBus
			], context.og, \addToTail);
			opB.map(\pitch,    Bus.newFrom(bus[\opPitch], 1));
			opB.map(\ratio,    Bus.newFrom(bus[\opRatio], 1));
			opB.map(\index,    Bus.newFrom(bus[\opIndex], 1));

			opA = Synth.new(\operatorFM, [
				\inBus, opBBus,
				\outBus, opABus
			], context.og, \addToTail);
			opA.map(\pitch,    Bus.newFrom(bus[\opPitch], 0));
			opA.map(\ratio,    Bus.newFrom(bus[\opRatio], 0));
			opA.map(\index,    Bus.newFrom(bus[\opIndex], 0));

			mixBus = bus[\mixAudio];
			opMixer = Synth.new(\operatorMixer, [
				\opA, opABus,
				\opB, opBBus,
				\bus, mixBus
			], context.og, \addToTail);
			opMixer.map(\mix, bus[\opMix]);

			fxA = Synth.new(\fxSquiz, [
				\bus, mixBus
			], context.og, \addToTail);
			fxA.map(\intensity, Bus.newFrom(bus[\fx], 0));
			controlSynth.set(\fxASynth, fxA);

			fxB = Synth.new(\fxWaveLoss, [
				\bus, mixBus
			], context.og, \addToTail);
			fxB.map(\intensity, Bus.newFrom(bus[\fx], 1));
			controlSynth.set(\fxBSynth, fxB);

			out = Synth.new(\voiceOutputStage, [
				\bus, mixBus
			], context.og, \addToTail);
			out.map(\amp,      bus[\amp]);
			out.map(\pan,      bus[\pan]);
			out.map(\hpCutoff, Bus.newFrom(bus[\cutoff], 0));
			out.map(\hpRQ,     Bus.newFrom(bus[\rq], 0));
			out.map(\lpCutoff, Bus.newFrom(bus[\cutoff], 1));
			out.map(\lpRQ,     Bus.newFrom(bus[\rq], 1));
			out.map(\outLevel, bus[\outLevel]);

			// TODO: Dictionary here too
			[ controlSynth, opA, opB, opMixer, fxA, fxB, lfoA, lfoB, lfoC, out ];
		});

		replySynth = Synth.new(\reply, [], context.og, \addToTail);

		polls = Array.fill(nVoices, {
			arg i;
			i = i + 1;
			Dictionary[
				// TODO: poll env value too, to show on grid??
				\instantPitch -> this.addPoll(("instant_pitch_" ++ i).asSymbol, periodic: false),
				\pitch -> this.addPoll(("pitch_" ++ i).asSymbol, periodic: false),
				\amp -> this.addPoll(("amp_" ++ i).asSymbol, periodic: false),
				\lfos -> [
					this.addPoll(("lfoA_gate_" ++ i).asSymbol, periodic: false),
					this.addPoll(("lfoB_gate_" ++ i).asSymbol, periodic: false),
					this.addPoll(("lfoC_gate_" ++ i).asSymbol, periodic: false)
				]
			];
		});

		opFadeReplyFunc = OSCFunc({
			arg msg;
			voiceOpStates[msg[3]][msg[4]][\fade] = msg[5];
			this.swapOp(msg[3], msg[4]);
		}, path: '/opFade', srcID: context.server.addr);

		opTypeReplyFunc = OSCFunc({
			arg msg;
			voiceOpStates[msg[3]][msg[4]][\type] = msg[5];
			this.swapOp(msg[3], msg[4]);
		}, path: '/opType', srcID: context.server.addr);

		fxTypeReplyFunc = OSCFunc({
			arg msg;
			var def = [\fxSquiz, \fxTanh, \fxFold, \fxWaveLoss, \fxDecimator, \fxChorus, \nothing].at(msg[5]);
			this.swapFx(msg[3], msg[4], def);
		}, path: '/fxType', srcID: context.server.addr);

		lfoTypeReplyFunc = OSCFunc({
			arg msg;
			var def = [\lfoTri, \lfoSH, \lfoDust, \lfoDrift, \lfoRamp, \nothing].at(msg[5]);
			this.swapLfo(msg[3], msg[4], def);
		}, path: '/lfoType', srcID: context.server.addr);

		voiceAmpReplyFunc = OSCFunc({
			arg msg;
			// msg looks like [ '/voiceAmp', ??, -1, voiceIndex, amp ]
			polls[msg[3]][\amp].update(msg[4]);
		}, path: '/voiceAmp', srcID: context.server.addr);

		voicePitchReplyFunc = OSCFunc({
			arg msg;
			// msg looks like [ '/voicePitch', ??, -1, voiceIndex, pitch, triggeredChange ]
			if(msg[5] == 1, {
				polls[msg[3]][\instantPitch].update(msg[4]);
			}, {
				polls[msg[3]][\pitch].update(msg[4]);
			});
		}, path: '/voicePitch', srcID: context.server.addr);

		lfoGateReplyFunc = OSCFunc({
			arg msg;
			// msg looks like [ '/lfoGate', ??, -1, voiceIndex, lfoIndex, state ]
			polls[msg[3]][\lfos][msg[4]].update(msg[5]);
		}, path: '/lfoGate', srcID: context.server.addr);

		this.addCommand(\select_voice, "i", {
			arg msg;
			// reset currently selected voice
			voiceSynths[selectedVoice][0].set(
				\gate, 0,
				\tip, 0,
				\palm, 0
				// we intentionally do NOT reset pitch, so that note doesn't change if envelope is still decaying
			);
			// select new voice
			selectedVoice = msg[1] - 1;
		});

		this.addCommand(\poll_rate, "f", {
			arg msg;
			replySynth.set(\replyRate, msg[1]);
		});

		this.addCommand(\baseFreq, "f", {
			arg msg;
			baseFreqBus.setSynchronous(msg[1]);
		});

		this.addCommand(\setLoop, "if", {
			arg msg;
			voiceSynths[msg[1] - 1][0].set(
				\loopLength, msg[2],
				\loopRateScale, 1,
				\freeze, 1
			);
		});

		this.addCommand(\resetLoopPhase, "i", {
			arg msg;
			voiceSynths[msg[1] - 1][0].set(\t_loopReset, 1);
		});

		this.addCommand(\clearLoop, "i", {
			arg msg;
			voiceSynths[msg[1] - 1][0].set(\freeze, 0);
		});

		patchArgs.do({
			arg name;
			this.addCommand(name, "f", { |msg|
				patchBuses[name].set(msg[1]);
			});
		});

		this.addCommand(\gate, "i", {
			arg msg;
			var value = msg[1];
			voiceSynths[selectedVoice][0].set(\gate, value, \trig, value);
		});

		// temporary command for determining the D50 samples' base frequency
		this.addCommand(\tuneSample, "f", {
			arg msg;
			var value = msg[1];
			voiceSynths[selectedVoice][1].set(\sampleBase, value);
		});

		[ \pitch, \tip, \palm ].do({
			arg name;
			this.addCommand(name, "f", { |msg|
				voiceSynths[selectedVoice][0].set(name, msg[1]);
			});
		});

		[
			\freeze,
			\loopRateScale,
			\shift,
			\pan,
			\outLevel,
		].do({
			arg name;
			this.addCommand(name, "if", { |msg|
				voiceSynths[msg[1] - 1][0].set(name, msg[2]);
			});
		});
	}

	free {
		sq80Resources.do({ |rsrc| rsrc.free });
		d50Resources.do({ |rsrc| rsrc.free });
		replySynth.free;
		voiceSynths.do({ |synths| synths.do({ |synth| synth.free }) });
		patchBuses.do({ |bus| bus.free });
		voiceBuses.do({ |dict| dict.do({ |bus| bus.free; }); });
		baseFreqBus.free;
		opFadeReplyFunc.free;
		opTypeReplyFunc.free;
		fxTypeReplyFunc.free;
		lfoTypeReplyFunc.free;
		voiceAmpReplyFunc.free;
		voicePitchReplyFunc.free;
		lfoGateReplyFunc.free;
	}
}
