Engine_Cule : CroneEngine {

	classvar nVoices = 6;
	classvar nRecordedModulators = 6;
	classvar bufferRateScale = 0.5;
	classvar maxLoopTime = 32;

	var voiceDef;
	var replyDef;

	var parameterNames;
	var modulatorNames;
	var voiceArgs;
	var patchArgs;

	var fmRatios;
	var nRatios;

	var baseFreqBus;
	var controlBuffers;
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

	// helper function to rungle two sources
	rungle {
		arg clock, sig;
		var buffer = LocalBuf(8);
		var pos = Stepper.kr(clock, 0, 0, 7);
		var r1 = BufRd.kr(1, buffer, (pos + 5) % 8, 0, 0);
		var r2 = BufRd.kr(1, buffer, (pos + 6) % 8, 0, 0);
		var r3 = BufRd.kr(1, buffer, (pos + 7) % 8, 0, 0);
		BufWr.kr(sig >= 0, buffer, pos);
		^(((r1 << 0) + (r2 << 1) + (r3 << 2)) / 7).lag(0.001);
	}

	alloc {

		// modulatable parameters for audio synths
		parameterNames = [
			\amp,
			\pitch,
			\pan,
			\tuneA,
			\tuneB,
			\fmIndex,
			\fbB,
			\opDetune,
			\opMix,
			\squiz,
			\lpgTone,
			\attack,
			\decay,
			\sustain,
			\release,
			\lfoAFreq,
			\lfoBFreq,
		];

		// modulation sources
		modulatorNames = [
			\pitch,
			\tip,
			\palm,
			\hand,
			\eg,
			\lfoA,
			\lfoB,
			\runglerA,
			\runglerB,
			\lfoSH
		];

		// non-patch, single-voice-specific args
		voiceArgs = [
			\voiceIndex,
			\voiceStateBus,
			\buffer,
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
		fmRatios = [1/8, 1/4, 1/2, 1, 2, 4, 6, 7, 8, 9, 11, 13].clump(2).flop;
		// fmRatios = ([1, 2, 4, 6, 7, 8, 9, 11, 12, 13, 14, 16] / 8).clump(2).flop;
		nRatios = fmRatios.flatten.size;

		baseFreqBus = Bus.control(context.server);

		// control-rate outputs for pitch, amp, trigger, and LFO states, to feed polls
		voiceStateBuses = Array.fill(nVoices, {
			Bus.control(context.server, 6);
		});

		controlBuffers = Array.fill(nVoices, {
			Buffer.alloc(context.server, context.server.sampleRate / context.server.options.blockSize * maxLoopTime * bufferRateScale, nRecordedModulators);
		});

		// TODO: LFOs as separate synths
		voiceDef = SynthDef.new(\line, {

			arg voiceIndex,
				buffer,
				pitch = 0,
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

				shift = 0,
				pitchSlew = 0.01,
				lpgTone = 0.6,
				attack = 0.01,
				decay = 0.1,
				sustain = 0.8,
				release = 0.3,
				egCurve = -6,
				lfoAFreq = 4.3,
				lfoBFreq = 3.1,
				tuneA = 0,
				tuneB = 0.3,
				fmIndex = 0,
				fbB = 0,
				opDetune = 0,
				opMix = 0,
				squiz = 0,
				pan = 0,
				lag = 0.1,

				detuneType = 0.2,
				fadeSize = 0.5,
				hpCutoff = 16,
				outLevel = 0.2;

			var bufferRate, bufferLength, bufferPhase,
				loopStart, loopPhase, loopTrigger, loopOffset,
				modulation = Dictionary.new,
				adsr, eg, amp, lpgOpenness,
				runglerA, runglerB, lfoA, lfoB, lfoEqual, lfoSH,
				hz, detuneLin, detuneExp,
				fmInput, opB, fmMix, opA,
				waveLossCount, squizRatio,
				lpgCutoff,
				voiceOutput,
				highPriorityUpdate;

			// calculate modulation matrix

			// this feedback loop is needed in order for modulators to modulate one another
			var modulators = LocalIn.kr(modulatorNames.size);

			// create buffer for looping pitch/amp/control data
			bufferRate = ControlRate.ir * bufferRateScale;
			bufferLength = BufFrames.kr(buffer);
			bufferPhase = Phasor.kr(rate: bufferRateScale * (1 - freeze), end: bufferLength);
			loopStart = bufferPhase - (loopLength * bufferRate).min(bufferLength);
			loopPhase = Phasor.kr(Trig.kr(freeze) + t_loopReset, bufferRateScale * loopRateScale, loopStart, bufferPhase, loopStart);
			// TODO: confirm that this is really firing when it's supposed to (i.e. when loopPhase
			// resets)! if not, either fix it, or do away with it
			loopTrigger = Trig.kr(BinaryOpUGen.new('==', loopPhase, loopStart));
			loopOffset = Latch.kr(bufferLength - (loopLength * bufferRate), loopTrigger) * loopPosition;
			loopPhase = loopPhase - loopOffset;
			t_trig = Trig.kr(t_trig, 0.01);
			BufWr.kr([pitch, tip, palm, gate, t_trig], buffer, bufferPhase);
			# pitch, tip, palm, gate, t_trig = Select.kr(freeze, [
				[pitch, tip, palm, gate, t_trig],
				BufRd.kr(nRecordedModulators, buffer, loopPhase, interpolation: 1)
			]);

			// build a dictionary of summed modulation signals to apply to parameters
			parameterNames.do({ |paramName|
				modulation.put(paramName, Mix.fill(modulatorNames.size, { |m|
					modulators[m] * NamedControl.kr((modulatorNames[m].asString ++ '_' ++ paramName.asString).asSymbol, 0, lag);
				}));
			});

			attack = attack * 8.pow(modulation[\attack]);
			decay = decay * 8.pow(modulation[\decay]);
			sustain = (sustain + modulation[\sustain]).clip;
			release = release * 8.pow(modulation[\release]);
			eg = Select.kr(\egType.kr(2), [
				// ADSR, linear attack
				EnvGen.kr(Env.new(
					[0, 1, sustain, 0],
					[attack, decay, release],
					egCurve * [0, 1, 1],
					releaseNode: 2
				), gate),
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
			lfoA = LFTri.kr(lfoAFreq);
			lfoBFreq = lfoBFreq * 8.pow(modulation[\lfoBFreq]);
			lfoB = LFTri.kr(lfoBFreq);
			runglerA = this.rungle(lfoA, lfoB);
			runglerB = this.rungle(lfoB, lfoA);
			lfoEqual = BinaryOpUGen('>=', lfoA, lfoB);
			lfoSH = Latch.kr(lfoA, Changed.kr(lfoEqual));

			// apply a pre-modulation dead zone to squiz control, so it's easier to hit 0
			squiz = squiz.sign * (1 - (1.1 * (1 - squiz.abs)).min(1));
			// TODO: scale? cube?

			// this weird-looking LinSelectX pattern scales modulation signals so that
			// final parameter values (base + modulation) can always reach [-1, 1]
			tuneA    = LinSelectX.kr(1 + modulation[\tuneA],    [-1, tuneA.lag(lag),    1 ]);
			tuneB    = LinSelectX.kr(1 + modulation[\tuneB],    [-1, tuneB.lag(lag),    1 ]);
			fmIndex  = LinSelectX.kr(1 + modulation[\fmIndex],  [-1, fmIndex.lag(lag),  1 ]);
			fbB      = LinSelectX.kr(1 + modulation[\fbB],      [-1, fbB.lag(lag),      1 ]);
			opDetune = LinSelectX.kr(1 + modulation[\opDetune], [-1, opDetune.cubed.lag(lag), 1 ]);
			opMix    = LinSelectX.kr(1 + modulation[\opMix],    [-1, opMix.lag(lag),    1 ]);
			squiz    = LinSelectX.kr(1 + modulation[\squiz],    [-1, squiz.lag(lag),    1 ]);
			lpgTone  = LinSelectX.kr(1 + modulation[\lpgTone],  [-1, lpgTone.lag(lag),  1 ]);
			pan      = LinSelectX.kr(1 + modulation[\pan],      [-1, pan.lag(lag),      1 ]);

			// now we're done with the modulation matrix

			LocalOut.kr([pitch, tip, palm, tip - palm, eg, lfoA, lfoB, runglerA, runglerB, lfoSH]);

			// slew tip for direct control of amplitude -- otherwise there will be audible steppiness
			tip = Lag.kr(tip, 0.05);
			// amp mode shouldn't change while frozen
			ampMode = Gate.kr(ampMode, 1 - freeze);
			amp = (Select.kr(ampMode, [
				tip,
				tip * eg,
				eg * -6.dbamp
			]) * (1 + modulation[\amp])).clip(0, 1);
			// scaled version of amp that allows env to fully open the LPG filter
			lpgOpenness = amp * Select.kr((ampMode == 2).asInteger, [1, 6.dbamp]).lag;

			pitch = pitch + (modulation[\pitch] / 4) + shift;

			// send control values to bus for polling
			Out.kr(\voiceStateBus.ir, [amp, pitch, t_trig, lfoA > 0, lfoB > 0, lfoEqual]);

			// TODO: why can't I use MovingAverage.kr here to get a linear slew?!
			// if I try that, SC seems to just hang forever, no error message
			pitch = Lag.kr(pitch, pitchSlew);

			hz = 2.pow(pitch) * In.kr(baseFreqBus);
			detuneLin = opDetune * 40 * detuneType;
			detuneExp = (opDetune * 7 * (1 - detuneType)).midiratio;
			opB = this.harmonicOsc(
				SinOscFB,
				hz / detuneExp - detuneLin,
				tuneB,
				fadeSize,
				fbB.lincurve(-1, 1, 0, pi, 3)
			);
			fmMix = opB * fmIndex.lincurve(-1, 1, 0, 10pi, 4);
			fmMix = fmMix.mod(2pi);
			opA = this.harmonicOsc(
				SinOsc,
				hz * detuneExp + detuneLin,
				tuneA,
				fadeSize,
				fmMix
			);

			voiceOutput = SelectX.ar(opMix.linlin(-1, 1, 0, 4), [
				opA,
				opB,
				opA * opB,
				opA,
				opB
			]);

			waveLossCount = squiz.neg.squared.linlin(0, 1, 0, 79);
			squizRatio = squiz.cubed.linlin(0, 1, 1, 16);
			voiceOutput = Select.ar(squiz > 0, [
				WaveLoss.ar(voiceOutput, waveLossCount, 80, mode: 2),
				Squiz.ar(voiceOutput, squizRatio, 2)
			]);

			// filter LPG-style
			lpgCutoff = lpgOpenness.lincurve(
				0, 1,
				lpgTone.lincurve(0, 1, 20, 20000, 4), lpgTone.lincurve(-1, 0, 20, 20000, 4),
				\lpgCurve.kr(3)
			);

			voiceOutput = Select.ar(\lpgOn.kr(1), [
				voiceOutput,
				RLPF.ar(voiceOutput, lpgCutoff, \lpgQ.kr(1.414).reciprocal)
			]);
			// scale by amplitude control value
			voiceOutput = voiceOutput * amp;

			// filter and write to main outs
			voiceOutput = HPF.ar(voiceOutput, hpCutoff.lag(lag));
			Out.ar(context.out_b, Pan2.ar(voiceOutput * Lag.kr(outLevel, 0.05), pan));
		}).add;

		patchArgs = voiceDef.allControlNames.collect({ |control| control.name }).difference(voiceArgs);

		replyDef = SynthDef.new(\reply, {
			arg selectedVoice = 0,
				replyRate = 15;
			var replyTrig = Impulse.kr(replyRate);
			nVoices.do({ |v|
				var isSelected = BinaryOpUGen('==', selectedVoice, v);
				var amp, pitch, trig, lfoA, lfoB, lfoEqual, pitchTrig;
				# amp, pitch, trig, lfoA, lfoB, lfoEqual = In.kr(voiceStateBuses[v], 6);

				// what's important is peak amplitude, not exact current amplitude at poll time
				amp = Peak.kr(amp, replyTrig);
				SendReply.kr(Peak.kr(Changed.kr(amp), replyTrig) * replyTrig, '/voiceAmp', [v, amp]);

				// respond quickly to triggers, which may change pitch in a meaningful way, even if the change is small
				pitchTrig = replyTrig + trig;
				SendReply.kr(Peak.kr(Changed.kr(pitch), pitchTrig) * pitchTrig, '/voicePitch', [v, pitch, trig]);

				// respond immediately to all LFO changes
				SendReply.kr(Changed.kr(lfoA) * isSelected, '/lfoGate', [v, 0, lfoA]);
				SendReply.kr(Changed.kr(lfoB) * isSelected, '/lfoGate', [v, 1, lfoB]);
				SendReply.kr(Changed.kr(lfoEqual) * isSelected, '/lfoGate', [v, 2, lfoEqual]);
			});
		}).add;

		// TODO: master bus FX like saturation, decimation...?

		context.server.sync;

		baseFreqBus.setSynchronous(60.midicps);

		patchBuses = Dictionary.new;
		voiceDef.allControlNames.do({
			arg control;
			if(patchArgs.includes(control.name), {
				var bus = Bus.control(context.server);
				bus.set(control.defaultValue);
				patchBuses.put(control.name, bus);
			});
		});

		voiceSynths = Array.fill(nVoices, {
			arg i;
			var synth = Synth.new(\line, [
				\voiceIndex, i,
				\buffer, controlBuffers[i],
				\voiceStateBus, voiceStateBuses[i],
			], context.og, \addToTail); // "output" group
			patchArgs.do({ |name| synth.map(name, patchBuses[name]) });
			synth;
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
					this.addPoll(("lfoEqual_gate_" ++ i).asSymbol, periodic: false)
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

		this.addCommand(\setLoop, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(
				\loopLength, msg[2],
				\loopRateScale, 1,
				\freeze, 1
			);
		});

		this.addCommand(\resetLoopPhase, "i", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\t_loopReset, 1);
		});

		this.addCommand(\clearLoop, "i", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\freeze, 0);
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
			voiceSynths[msg[1] - 1].set(\gate, value, \t_trig, value);
		});

		voiceArgs.do({
			arg name;
			if(name !== \gate, {
				this.addCommand(name, "if", { |msg|
					voiceSynths[msg[1] - 1].set(name, msg[2]);
				});
			});
		});
	}

	free {
		replySynth.free;
		voiceSynths.do({ |synth| synth.free });
		controlBuffers.do({ |buffer| buffer.free });
		patchBuses.do({ |bus| bus.free });
		voiceAmpReplyFunc.free;
		voicePitchReplyFunc.free;
		lfoGateReplyFunc.free;
	}
}
