Engine_Cule : CroneEngine {

	classvar nVoices = 5;
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

	alloc {

		// modulatable parameters for audio synths
		parameterNames = [
			\amp,
			\pan,
			\ratioA,
			\detuneA,
			\fmIndex,
			\ratioB,
			\detuneB,
			\fbB,
			\opMix,
			\squiz,
			\loss,
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
				fmIndex = 0,

				opMix = 0,

				ratioB = 0.3,
				fadeSizeB = 0.5,
				detuneB = 0,
				fbB = 0,

				squiz = 0,
				loss = 0,

				pan = 0,
				lag = 0.1,

				outLevel = 0.2;

			var bufferRate, bufferLength, bufferPhase,
				loopStart, loopPhase, loopTrigger, loopOffset,
				modulation = Dictionary.new,
				recPitch, recTip, recHand, recGate, recTrig,
				hand, freezeWithoutGate, eg, eg2, amp,
				lfoA, lfoB, lfoC,
				lfoSHAB, lfoSHBC, lfoSHCA,
				hz, fmInput, opB, fmMix, opA,
				hpRQ, lpRQ,
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
					modulators[m] * NamedControl.kr((modulatorNames[m].asString ++ '_' ++ paramName.asString).asSymbol, 0, lag);
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

			// params with additive modulation
			detuneA  = detuneA.cubed.lag(lag) + modulation[\detuneA];
			fmIndex  = fmIndex.lag(lag) + modulation[\fmIndex];
			opMix    = opMix.lag(lag) + modulation[\opMix];
			detuneB  = detuneB.cubed.lag(lag) + modulation[\detuneB];
			fbB      = fbB.lag(lag) + modulation[\fbB];
			hpCutoff = hpCutoff.lag(lag) + modulation[\hpCutoff];
			lpCutoff = lpCutoff.lag(lag) + modulation[\lpCutoff];

			// multiplicative modulation
			squiz    = squiz.lag(lag) * 4.pow(modulation[\squiz]);

			// this weird-looking LinSelectX pattern scales modulation signals so that
			// final parameter values (base + modulation) can reach [-1, 1], but not go beyond
			ratioA   = LinSelectX.kr(1 + modulation[\ratioA],   [-1, ratioA.lag(lag),   1 ]);
			ratioB   = LinSelectX.kr(1 + modulation[\ratioB],   [-1, ratioB.lag(lag),   1 ]);
			pan      = LinSelectX.kr(1 + modulation[\pan],      [-1, pan.lag(lag),      1 ]);

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

			pitch = pitch + shift;

			// send control values to bus for polling
			Out.kr(\voiceStateBus.ir, [amp, pitch, t_trig, lfoA > 0, lfoB > 0, lfoC > 0]);

			// TODO: why can't I use MovingAverage.kr here to get a linear slew?!
			// if I try that, SC seems to just hang forever, no error message
			pitch = Lag.kr(pitch, pitchSlew);

			hz = 2.pow(pitch) * In.kr(baseFreqBus);
			opB = this.harmonicOsc(
				SinOscFB,
				hz * (9 / 4).pow(detuneB),
				ratioB,
				fadeSizeB,
				fbB.lincurve(-1, 1, 0, pi, 3, \min)
			);
			// FM index gets scaled by a factor of 0.7 per octave (exponential). this
			// makes timbre feel more evenly balanced across a range of several octaves.
			fmMix = opB * fmIndex.lincurve(-1, 1, 0, 10pi, 4, \min) * 0.7.pow(pitch);
			fmMix = fmMix.mod(2pi);
			opA = this.harmonicOsc(
				SinOsc,
				hz * (9 / 4).pow(detuneA),
				ratioA,
				fadeSizeA,
				fmMix
			);


			// gotta convert to audio rate before wrapping or we get glitches when crossing the wrap point
			voiceOutput = SelectX.ar(K2A.ar(opMix.linlin(-1, 1, 0, 4, nil)).wrap(0, 3), [
				opA,
				opB,
				opA * opB * 3.dbamp, // compensate for amplitude loss from sine * sine
				opA,
			]);

			// apply FX
			voiceOutput = WaveLoss.ar(voiceOutput, loss.lincurve(-1, 1, 0, 127, 4), 127, mode: 2);
			voiceOutput = Squiz.ar(voiceOutput, squiz.lincurve(-1, 1, 1, 16, 4), 2);

			hpCutoff = hpCutoff.linexp(-1, 1, 4, 24000);
			hpRQ = \hpRQ.kr(0.7);
			hpRQ = hpCutoff.linexp(SampleRate.ir * 0.25 / hpRQ, SampleRate.ir * 0.5, hpRQ, 0.5).min(hpRQ);
			voiceOutput = Select.ar(\hpOn.kr(1), [
				voiceOutput,
				RHPF.ar(voiceOutput, hpCutoff, hpRQ)
			]);
			lpCutoff = lpCutoff.linexp(-1, 1, 4, 24000);
			lpRQ = \lpRQ.kr(0.7);
			lpRQ = lpCutoff.linexp(SampleRate.ir * 0.25 / lpRQ, SampleRate.ir * 0.5, lpRQ, 0.5).min(lpRQ);
			voiceOutput = Select.ar(\lpOn.kr(1), [
				voiceOutput,
				RLPF.ar(voiceOutput, lpCutoff, lpRQ)
			]);

			// scale by amplitude control value
			voiceOutput = voiceOutput * amp;

			// filter and write to main outs
			Out.ar(context.out_b, Pan2.ar(voiceOutput * Lag.kr(outLevel, 0.05), pan));
		}).add;

		patchArgs = voiceDef.allControlNames.collect({ |control| control.name }).difference(voiceArgs);

		replyDef = SynthDef.new(\reply, {
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
