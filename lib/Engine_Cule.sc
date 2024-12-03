Engine_Cule : CroneEngine {

	classvar nVoices = 5;
	classvar nRecordedModulators = 6;
	classvar bufferRateScale = 0.5;
	classvar maxLoopTime = 60;

	var controlDef;

	var parameterNames;
	var modulatorNames;
	var voiceArgs;
	var patchArgs;

	var fmRatios;
	var nRatios;

	var baseFreqBus;
	var audioBuses;
	var controlBuses;
	var voiceSynths;
	var patchBuses;
	var replySynth;
	var voiceStateBuses;
	var polls;
	var voiceAmpReplyFunc;
	var voicePitchReplyFunc;
	var lfoGateReplyFunc;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	// helper function / pseudo-UGen: an FM operator that can crossfade its tuning across a set
	// of predefined ratios
	harmonicOsc {
		arg uGen, hz, harmonic, fadeSize, uGenArg;
		var whichRatio = harmonic.linlin(-1, 1, 0, nRatios - 1);
		var whichOsc = (Fold.kr(whichRatio).linlin(0, 1, -1, 1) / fadeSize).clip2;
		^LinXFade2.ar(
			uGen.ar(hz * Select.kr(whichRatio + 1 / 2, fmRatios[0]), uGenArg),
			uGen.ar(hz * Select.kr(whichRatio / 2, fmRatios[1]), uGenArg),
			whichOsc
		);
	}

	swapOp {
		arg op, defName; // op A = 0, B = 1
		nVoices.do({ |v|
			var thisBus = Bus.newFrom(audioBuses[v], op + 1);
			var thatBus = Bus.newFrom(audioBuses[v], (op + 1).mod(2) + 1);
			var newOp = Synth.replace(voiceSynths[v][op + 1], defName, [
				\inBus, thatBus,
				\outBus, thisBus
			]);
			newOp.map(\pitch,    Bus.newFrom(controlBuses[v], 0));
			newOp.map(\ratio,    Bus.newFrom(controlBuses[v], op * 4 + 3));
			newOp.map(\fadeSize, Bus.newFrom(controlBuses[v], op * 4 + 4));
			newOp.map(\detune,   Bus.newFrom(controlBuses[v], op * 4 + 5));
			newOp.map(\index,    Bus.newFrom(controlBuses[v], op * 4 + 6));
			voiceSynths[v].put(op + 1, newOp);
		});
	}

	swapFx {
		arg slot, defName;
		nVoices.do({ |v|
			var bus = Bus.newFrom(audioBuses[v], 0);
			var newFx = Synth.replace(voiceSynths[v][slot + 4], defName, [
				\bus, bus
			]);
			newFx.map(\intensity, Bus.newFrom(controlBuses[v], 12 + slot));
			voiceSynths[v].put(slot + 4, newFx);
		});
	}

	alloc {

		// modulatable parameters for audio synths
		parameterNames = [
			\amp,
			\pan,
			\ratioA,
			\detuneA,
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

		// modulation sources
		modulatorNames = [
			\amp,
			\hand,
			\eg,
			\eg2,
			\lfoA,
			\lfoB,
			\lfoC,
			\lfoAB,
			\lfoBC,
			\lfoCA
		];

		// non-patch, single-voice-specific args
		voiceArgs = [
			\voiceStateBus,
			\pitch,
			\gate,
			\t_trig,
			\tip,
			\palm,
			\freeze,
			\t_loopReset,
			\loopLength,
			\loopPosition,
			\loopRateScale,
			\shift,
			\pan,
			\outLevel,
		];

		// frequency ratios used by the two FM operators of each voice
		// declared as one array, but stored as two arrays, one with odd and one with even
		// members of the original; this allows operators to crossfade between two ratios
		// (see harmonicOsc function)
		fmRatios = [1/128, 1/64, 1/32, 1/16, 1/8, 1/4, 1/2,
			1, 2, /* 3, */ 4, /* 5, */ 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16].clump(2).flop;
		// fmRatios = ([1, 2, 4, 6, 7, 8, 9, 11, 12, 13, 14, 16] / 8).clump(2).flop;
		nRatios = fmRatios.flatten.size;

		baseFreqBus = Bus.control(context.server);

		// control-rate outputs for pitch, amp, trigger, and LFO states, to feed polls
		voiceStateBuses = Array.fill(nVoices, {
			Bus.control(context.server, 6);
		});

		audioBuses = Array.fill(nVoices, {
			Bus.audio(context.server, 3);
		});

		controlBuses = Array.fill(nVoices, {
			Bus.control(context.server, 19);
		});

		controlDef = SynthDef.new(\voiceControls, {

			arg pitch = 0,
				gate = 0,
				t_trig = 0,
				tip = 0,
				palm = 0,
				ampMode = 0, // 0 = tip only; 1 = tip * AR; 2 = ADSR
				freeze = 0,
				t_loopReset = 0,
				loopLength = 0.3,
				loopPosition = 0,
				loopRateScale = 1,

				hpCutoff = 0.0,
				lpCutoff = 0.8,

				attack = 0.01,
				release = 0.3,
				egCurve = -6,

				lfoAFreq = 4.3,
				lfoBFreq = 3.1,
				lfoCFreq = 1.1,

				ratioA = 0,
				fadeSizeA = 0.5,
				detuneA = 0,
				indexA = 0,

				opMix = 0,

				ratioB = 0.3,
				fadeSizeB = 0.5,
				detuneB = 0,
				indexB = 0,

				fxA = 0,
				fxB = 0,

				pan = 0,
				lag = 0.1;

			var bufferRate, bufferLength, bufferPhase, buffer,
				loopStart, loopPhase, loopTrigger, loopOffset,
				modulation = Dictionary.new,
				amp_indexA, amp_indexB, amp_hpCutoff, amp_lpCutoff,
				recPitch, recTip, recHand, recGate, recTrig,
				hand, freezeWithoutGate, eg, eg2, amp,
				lfoA, lfoB, lfoC,
				lfoSHAB, lfoSHBC, lfoSHCA,
				hz, fmInput, opB, fmMix, opA,
				voiceOutput,
				highPriorityUpdate;

			// calculate modulation matrix

			// this feedback loop is needed in order for modulators to modulate one another
			var modulators = LocalIn.kr(modulatorNames.size);

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
			t_trig = Trig.kr(t_trig, 0.01);
			hand = tip - palm;
			freezeWithoutGate = freeze.min(1 - gate);
			BufWr.kr([pitch, tip, hand, gate, t_trig], buffer, bufferPhase);
			// read values from recorded loop (if any)
			# recPitch, recTip, recHand, recGate, recTrig = BufRd.kr(nRecordedModulators, buffer, loopPhase, interpolation: 1);
			// new pitch values can "punch through" frozen ones when gate is high
			pitch = Select.kr(freezeWithoutGate, [ pitch, recPitch ]);
			// punch tip through too, only when gate is high
			tip = Select.kr(freezeWithoutGate, [ tip, recTip ]);
			// mix incoming hand data with recorded hand (fade in when freeze is engaged)
			hand = hand + (Linen.kr(freeze, 0.3, 1, 0) * recHand);
			// combine incoming gates with recorded gates
			gate = gate.max(freeze * recGate);
			t_trig = t_trig.max(freeze * recTrig);

			// build a dictionary of summed modulation signals to apply to parameters
			parameterNames.do({ |paramName|
				modulation.put(paramName, Mix.fill(modulatorNames.size, { |m|
					var modulatorName = modulatorNames[m];
					// amp modulates index and cutoff differently: it always lowers the parameter, never
					// increases it. this way, default routing can include amp->index, but if index is set to
					// minimum, we'll always hear a sine wave.
					// amp ranges from 0 to 1, and amount from -1 to 1.
					// when amount is positive, low amp values lower index/cutoff. when amount is negative,
					// high amp values lower the index/cutoff.
					// in both cases, amp is scaled so that maximum reduction is 2.
					// except for HP cutoff, which works the opposite way: it is only ever raised.
					if(\amp === modulatorName && [\indexA, \indexB, \hpCutoff, \lpCutoff].includes(paramName), {
						var amount = NamedControl.kr(('amp_' ++ paramName).asSymbol, 0, lag);
						var polaritySwitch = BinaryOpUGen(if(\hpCutoff === modulatorName, '<', '>'), amount, 0);
						(modulators[m] - polaritySwitch) * 2 * amount;
					}, {
						modulators[m] * NamedControl.kr((modulatorName ++ '_' ++ paramName).asSymbol, 0, lag);
					});
				}));
			});

			attack = attack * 8.pow(modulation[\attack]);
			release = release * 8.pow(modulation[\release]);
			eg = Select.kr(\egType.kr(1), [
				// ASR, linear attack
				EnvGen.kr(Env.new(
					[0, 1, 0],
					[attack, release],
					egCurve * [0, 1],
					releaseNode: 1
				), gate),
				// AR, Maths-style symmetrical attack
				EnvGen.kr(Env.new(
					[0, 1, 0],
					[attack, release],
					egCurve * [-1, 1],
				), t_trig)
			]);

			lfoAFreq = lfoAFreq * 8.pow(modulation[\lfoAFreq]);
			lfoA = LFTri.kr(lfoAFreq, 4.rand);
			lfoBFreq = lfoBFreq * 8.pow(modulation[\lfoBFreq]);
			lfoB = LFTri.kr(lfoBFreq, 4.rand);
			lfoCFreq = lfoCFreq * 8.pow(modulation[\lfoCFreq]);
			lfoC = LFTri.kr(lfoCFreq, 4.rand);

			lfoSHAB = Latch.kr(lfoB, lfoA > 0);
			lfoSHBC = Latch.kr(lfoC, lfoB > 0);
			lfoSHCA = Latch.kr(lfoA, lfoC > 0);

			detuneA  = detuneA.cubed.lag(lag) + modulation[\detuneA];
			indexA   = indexA.lag(lag) + modulation[\indexA];
			opMix    = opMix.lag(lag) + modulation[\opMix];
			detuneB  = detuneB.cubed.lag(lag) + modulation[\detuneB];
			indexB   = indexB.lag(lag) + modulation[\indexB];
			hpCutoff = hpCutoff.lag(lag) + modulation[\hpCutoff];
			lpCutoff = lpCutoff.lag(lag) + modulation[\lpCutoff];
			fxA      = fxA.lag(lag) + modulation[\fxA];
			fxB      = fxB.lag(lag) + modulation[\fxB];
			pan      = pan.lag(lag) + modulation[\pan];
			ratioA   = ratioA.lag(lag) + modulation[\ratioA];
			ratioB   = ratioB.lag(lag) + modulation[\ratioB];

			// slew tip for direct control of amplitude -- otherwise there will be audible steppiness
			tip = Lag.kr(tip, 0.05);
			// amp mode shouldn't change while frozen
			ampMode = Gate.kr(ampMode, 1 - freeze);
			amp = (Select.kr(ampMode, [
				tip,
				tip * eg,
				eg * -6.dbamp
			]) * (1 + modulation[\amp])).clip(0, 1);

			// now save the modulation values for the next block
			LocalOut.kr([
				amp,
				hand,
				eg,
				eg * eg,
				lfoA,
				lfoB,
				lfoC,
				lfoSHAB,
				lfoSHBC,
				lfoSHCA
			]);

			pitch = pitch + \shift.kr;

			// send control values to bus for polling
			Out.kr(\voiceStateBus.ir, [amp, pitch, t_trig, lfoA > 0, lfoB > 0, lfoC > 0]);

			// TODO: why can't I use MovingAverage.kr here to get a linear slew?!
			// if I try that, SC seems to just hang forever, no error message
			pitch = Lag.kr(pitch, \pitchSlew.kr);

			Out.kr(\controlBus.ir, [
				// grouped in fives for easy counting
				pitch, amp, pan, ratioA, fadeSizeA,
				detuneA, indexA, ratioB, fadeSizeB, detuneB,
				indexB, opMix, fxA, fxB, hpCutoff,
				\hpRQ.kr(0.7), lpCutoff, \lpRQ.kr(0.7), \outLevel.kr(0.2)
			]);
		}).add;

		// Self-FM operator
		SynthDef.new(\operatorFB, {
			var hz = 2.pow(\pitch.kr) * In.kr(baseFreqBus);
			var output = this.harmonicOsc(
				SinOscFB,
				hz * (9 / 4).pow(\detune.kr),
				\ratio.kr,
				\fadeSize.kr(1),
				\index.kr(-1).lincurve(-1, 1, 0, pi, 3, \min)
			);
			Out.ar(\outBus.ir, output);
		}).add;

		// External-FM operator
		SynthDef.new(\operatorFM, {
			var pitch = \pitch.kr;
			var hz = 2.pow(pitch) * In.kr(baseFreqBus);
			var output = this.harmonicOsc(
				SinOsc,
				hz * (9 / 4).pow(\detune.kr),
				\ratio.kr,
				\fadeSize.kr(1),
				(InFeedback.ar(\inBus.ir) * \index.kr(-1).lincurve(-1, 1, 0, 10pi, 4, \min) * 0.7.pow(pitch)).mod(2pi)
			);
			Out.ar(\outBus.ir, output);
		}).add;

		SynthDef.new(\operatorMixer, {
			var opA = In.ar(\opA.ir);
			var opB = In.ar(\opB.ir);
			// mix param is audio rate so it can be wrapped without audible glitches when wrapping
			// TODO: make sure using \mix.ar does the proper KR->AR conversion -- test by listening for
			// glitches when crossing the wrap point
			var output = SelectX.ar(\mix.ar.linlin(-1, 1, 0, 4, nil).wrap(0, 3), [
				opA,
				opB,
				opA * opB * 3.dbamp, // compensate for amplitude loss from sine * sine
				opA
			]);
			Out.ar(\bus.ir, output);
		}).add;

		SynthDef.new(\fxSquiz, {
			var bus = \bus.ir;
			ReplaceOut.ar(bus, Squiz.ar(In.ar(bus), \intensity.kr.lincurve(-1, 1, 1, 16, 4, 'min'), 2));
		}).add;

		SynthDef.new(\fxWaveLoss, {
			var bus = \bus.ir;
			ReplaceOut.ar(bus,
				WaveLoss.ar(In.ar(bus), \intensity.kr.lincurve(-1, 1, 0, 127, 4, 'min'), 127, mode: 2)
			);
		}).add;

		SynthDef.new(\fxFold, {
			var bus = \bus.ir;
			ReplaceOut.ar(bus, (In.ar(bus) * \intensity.kr.linexp(-1, 1, 1, 27, 'min')).fold2);
		}).add;

		// Dimension C-style chorus
		SynthDef.new(\fxChorus, {
			var bus = \bus.ir;
			var sig = In.ar(bus);
			var intensity = \intensity.kr;
			var lfo = LFTri.kr(intensity.linexp(-1, 1, 0.03, 2, nil)).lag(\lag.kr(0.1)) * [-1, 1];
			sig = Mix([
				sig,
				DelayL.ar(sig, 0.05, lfo * intensity.linexp(-1, 1, 0.0019, 0.005, nil) + [\d1.kr(0.01), \d2.kr(0.007)])
			].flatten);
			ReplaceOut.ar(bus, sig * -6.dbamp);
		}).add;

		SynthDef.new(\voiceOutputStage, {

			var hpCutoff, hpRQ,
				lpCutoff, lpRQ;
			var voiceOutput = In.ar(\bus.ir);

			// HPF
			hpCutoff = \hpCutoff.kr(-1).linexp(-1, 1, 4, 24000);
			hpRQ = \hpRQ.kr(0.7);
			hpRQ = hpCutoff.linexp(SampleRate.ir * 0.25 / hpRQ, SampleRate.ir * 0.5, hpRQ, 0.5).min(hpRQ);
			voiceOutput = RHPF.ar(voiceOutput, hpCutoff, hpRQ);

			// LPF
			lpCutoff = \lpCutoff.kr(1).linexp(-1, 1, 4, 24000);
			lpRQ = \lpRQ.kr(0.7);
			lpRQ = lpCutoff.linexp(SampleRate.ir * 0.25 / lpRQ, SampleRate.ir * 0.5, lpRQ, 0.5).min(lpRQ);
			voiceOutput = RLPF.ar(voiceOutput, lpCutoff, lpRQ);

			// scale by amplitude control value
			voiceOutput = voiceOutput * \amp.kr;

			// scale by output level
			voiceOutput * Lag.kr(\outLevel.kr, 0.05)

			// pan and write to main outs
			Out.ar(context.out_b, Pan2.ar(voiceOutput, \pan.kr.fold2));
		}).add;

		patchArgs = controlDef.allControlNames.collect({ |control| control.name }).difference(voiceArgs);

		SynthDef.new(\reply, {
			arg selectedVoice = 0,
				replyRate = 15;
			var replyTrig = Impulse.kr(replyRate);
			nVoices.do({ |v|
				var isSelected = BinaryOpUGen('==', selectedVoice, v);
				var amp, pitch, trig, lfoA, lfoB, lfoC, pitchTrig;
				# amp, pitch, trig, lfoA, lfoB, lfoC = In.kr(voiceStateBuses[v], 6);

				// what's important is peak amplitude, not exact current amplitude at poll time
				amp = Peak.kr(amp, replyTrig);
				SendReply.kr(Peak.kr(Changed.kr(amp), replyTrig) * replyTrig, '/voiceAmp', [v, amp]);

				// respond quickly to triggers, which may change pitch in a meaningful way, even if the change is small
				pitchTrig = replyTrig + trig;
				SendReply.kr(Peak.kr(Changed.kr(pitch), pitchTrig) * pitchTrig, '/voicePitch', [v, pitch, trig]);

				// respond immediately to all LFO changes
				SendReply.kr(Changed.kr(lfoA) * isSelected, '/lfoGate', [v, 0, lfoA]);
				SendReply.kr(Changed.kr(lfoB) * isSelected, '/lfoGate', [v, 1, lfoB]);
				SendReply.kr(Changed.kr(lfoC) * isSelected, '/lfoGate', [v, 2, lfoC]);
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

		voiceSynths = Array.fill(nVoices, {
			arg i;

			var controlSynth,
				opBBus, opB, opABus, opA,
				mixBus, opMixer, fxB, fxA,
				out;

			controlSynth = Synth.new(\voiceControls, [
				\controlBus, controlBuses[i],
				\voiceStateBus, voiceStateBuses[i],
			], context.og, \addToTail); // "output" group
			patchArgs.do({ |name| controlSynth.map(name, patchBuses[name]) });

			opBBus = Bus.newFrom(audioBuses[i], 2);
			opABus = Bus.newFrom(audioBuses[i], 1);

			opB = Synth.new(\operatorFB, [
				\inBus, opABus,
				\outBus, opBBus
			], context.og, \addToTail);
			opB.map(\pitch,    Bus.newFrom(controlBuses[i], 0));
			opB.map(\ratio,    Bus.newFrom(controlBuses[i], 7));
			opB.map(\fadeSize, Bus.newFrom(controlBuses[i], 8));
			opB.map(\detune,   Bus.newFrom(controlBuses[i], 9));
			opB.map(\index,    Bus.newFrom(controlBuses[i], 10));

			opA = Synth.new(\operatorFB, [
				\inBus, opBBus,
				\outBus, opABus
			], context.og, \addToTail);
			opA.map(\pitch,    Bus.newFrom(controlBuses[i], 0));
			opA.map(\ratio,    Bus.newFrom(controlBuses[i], 3));
			opA.map(\fadeSize, Bus.newFrom(controlBuses[i], 4));
			opA.map(\detune,   Bus.newFrom(controlBuses[i], 5));
			opA.map(\index,    Bus.newFrom(controlBuses[i], 6));

			mixBus = Bus.newFrom(audioBuses[i], 0);
			opMixer = Synth.new(\operatorMixer, [
				\opA, opABus,
				\opB, opBBus,
				\bus, mixBus
			], context.og, \addToTail);
			opMixer.map(\mix, Bus.newFrom(controlBuses[i], 11));

			fxA = Synth.new(\fxSquiz, [
				\bus, mixBus
			], context.og, \addToTail);
			fxA.map(\intensity, Bus.newFrom(controlBuses[i], 12));

			fxB = Synth.new(\fxWaveLoss, [
				\bus, mixBus
			], context.og, \addToTail);
			fxB.map(\intensity, Bus.newFrom(controlBuses[i], 13));

			out = Synth.new(\voiceOutputStage, [
				\bus, mixBus
			], context.og, \addToTail);
			out.map(\amp,      Bus.newFrom(controlBuses[i], 1));
			out.map(\pan,      Bus.newFrom(controlBuses[i], 2));
			out.map(\hpCutoff, Bus.newFrom(controlBuses[i], 14));
			out.map(\hpRQ,     Bus.newFrom(controlBuses[i], 15));
			out.map(\lpCutoff, Bus.newFrom(controlBuses[i], 16));
			out.map(\lpRQ,     Bus.newFrom(controlBuses[i], 17));
			out.map(\outLevel, Bus.newFrom(controlBuses[i], 18));

			// TODO: return ALL synths so they can be freed, and replaced...
			// AND/OR, assign them all to a group so the whole group can be freed
			[ controlSynth, opB, opA, opMixer, fxA, fxB, out ];
		});

		replySynth = Synth.new(\reply, [], context.og, \addToTail);

		polls = Array.fill(nVoices, {
			arg i;
			i = i + 1;
			Dictionary[
				\instantPitch -> this.addPoll(("instant_pitch_" ++ i).asSymbol, periodic: false),
				\pitch -> this.addPoll(("pitch_" ++ i).asSymbol, periodic: false),
				\amp -> this.addPoll(("amp_" ++ i).asSymbol, periodic: false),
				\lfos -> [
					this.addPoll(("lfoA_gate_" ++ i).asSymbol, periodic: false),
					this.addPoll(("lfoB_gate_" ++ i).asSymbol, periodic: false),
					this.addPoll(("lfoC_gate_" ++ i).asSymbol, periodic: false),
					this.addPoll(("lfoAB_gate_" ++ i).asSymbol, periodic: false),
					this.addPoll(("lfoBC_gate_" ++ i).asSymbol, periodic: false),
					this.addPoll(("lfoCA_gate_" ++ i).asSymbol, periodic: false)
				]
			];
		});

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
			replySynth.set(\selectedVoice, msg[1] - 1);
		});

		this.addCommand(\poll_rate, "f", {
			arg msg;
			replySynth.set(\replyRate, msg[1]);
		});

		this.addCommand(\baseFreq, "f", {
			arg msg;
			baseFreqBus.setSynchronous(msg[1]);
		});

		this.addCommand(\opType, "ii", {
			arg msg;
			var def = if(msg[2] - 1 == 1, \operatorFB, \operatorFM);
			this.swapOp(msg[1] - 1, def);
		});

		this.addCommand(\fxType, "ii", {
			arg msg;
			var def = [\fxSquiz, \fxWaveLoss, \fxFold, \fxChorus].at(msg[2] - 1);
			this.swapFx(msg[1] - 1, def);
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
			var signature = if([ \ampMode ].includes(name), "i", "f");
			this.addCommand(name, signature, { |msg|
				patchBuses[name].set(msg[1]);
			});
		});

		this.addCommand(\gate, "ii", {
			arg msg;
			var value = msg[2];
			voiceSynths[msg[1] - 1][0].set(\gate, value, \t_trig, value);
		});

		voiceArgs.do({
			arg name;
			if(name !== \gate, {
				this.addCommand(name, "if", { |msg|
					voiceSynths[msg[1] - 1][0].set(name, msg[2]);
				});
			});
		});
	}

	free {
		replySynth.free;
		voiceSynths.do({ |synths| synths.do({ |synth| synth.free }) });
		patchBuses.do({ |bus| bus.free });
		voiceStateBuses.do({ |bus| bus.free });
		controlBuses.do({ |bus| bus.free });
		audioBuses.do({ |bus| bus.free });
		baseFreqBus.free;
		voiceAmpReplyFunc.free;
		voicePitchReplyFunc.free;
		lfoGateReplyFunc.free;
	}
}
