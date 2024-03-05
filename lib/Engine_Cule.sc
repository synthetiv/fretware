Engine_Cule : CroneEngine {

	classvar nVoices = 7;
	classvar nRecordedModulators = 6;
	classvar bufferRateScale = 0.5;
	classvar maxLoopTime = 32;

	var voiceDef;
	var replyDef;

	var parameterNames;
	var modulatorNames;

	var fmRatios;
	var nRatios;

	var baseFreqBus;
	var controlBuffers;
	var voiceSynths;
	var replySynth;
	var voiceStateBuses;
	var fmBuses;
	var polls;
	var voiceStateReplyFunc;
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
			\pitch,
			\pan,
			\tuneA,
			\tuneB,
			\fmIndex,
			\fbB,
			\opDetune,
			\opMix,
			\foldGain,
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
			\lfoB
		];

		// frequency ratios used by the two FM operators of each voice
		// declared as one array, but stored as two arrays, one with odd and one with even
		// members of the original; this allows operators to crossfade between two ratios
		// (see harmonicOsc function)
		fmRatios = [1/8, 1/4, 1/2, 1, 2, 4, 6, 7, 8, 9].clump(2).flop;
		nRatios = fmRatios.flatten.size;

		baseFreqBus = Bus.control(context.server);

		// control-rate outputs for pitch, amp, trigger, and LFO states, to feed polls
		voiceStateBuses = Array.fill(nVoices, {
			Bus.control(context.server, 5);
		});

		controlBuffers = Array.fill(nVoices, {
			Buffer.alloc(context.server, context.server.sampleRate / context.server.options.blockSize * maxLoopTime * bufferRateScale, nRecordedModulators);
		});

		"sending synthdef...".postln;

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
				delay = 0,
				freeze = 0,
				t_loopReset = 0,
				loopLength = 0.3,
				loopPosition = 0,
				loopRateScale = 1,

				tune = 0,
				pitchSlew = 0.01,
				lpgTone = 0.6,
				attack = 0.01,
				decay = 0.1,
				sustain = 0.8,
				release = 0.3,
				lfoAType = 0,
				lfoAFreq = 0.9,
				lfoBType = 0,
				lfoBFreq = 1.1,
				oscType = 1,
				tuneA = 0,
				tuneB = 0.3,
				fmIndex = 0,
				fbB = 0,
				opDetune = 0,
				opMix = 0,
				foldGain = 0,
				pan = 0,
				lag = 0.1,

				octave = 0,
				detuneType = 0.2,
				fadeSize = 0.5,
				hpCutoff = 16,
				outLevel = 0.2;

			var bufferRate, bufferLength, bufferPhase, delayPhase,
				loopStart, loopPhase, loopTrigger, loopOffset,
				modulation = Dictionary.new,
				adsr, eg, amp, lpgOpenness, lfoA, lfoB,
				hz, detuneLin, detuneExp,
				fmInput, opB, fmMix, opA,
				voiceOutput,
				highPriorityUpdate;

			// calculate modulation matrix

			// this feedback loop is needed in order for modulators to modulate one another
			var modulators = LocalIn.kr(modulatorNames.size);

			// create buffer for looping pitch/amp/control data
			bufferRate = ControlRate.ir * bufferRateScale;
			bufferLength = BufFrames.kr(buffer);
			bufferPhase = Phasor.kr(rate: bufferRateScale * (1 - freeze), end: bufferLength);
			// delay must be at least 1 frame, or we'll be writing to + reading from the same point
			delayPhase = bufferPhase - (delay * bufferRate).max(1);
			loopStart = bufferPhase - (loopLength * bufferRate).min(bufferLength);
			loopPhase = Phasor.kr(Trig.kr(freeze) + t_loopReset, bufferRateScale * loopRateScale, loopStart, bufferPhase, loopStart);
			// TODO: confirm that this is really firing when it's supposed to (i.e. when loopPhase
			// resets)! if not, either fix it, or do away with it
			loopTrigger = Trig.kr(BinaryOpUGen.new('==', loopPhase, loopStart));
			loopOffset = Latch.kr(bufferLength - (loopLength * bufferRate), loopTrigger) * loopPosition;
			loopPhase = loopPhase - loopOffset;
			// TODO: restore the ability for diff voices to have diff amp modes.
			// that means making it possible to decouple a voice's parameters from the global ones
			BufWr.kr([pitch, tip, palm, gate, Trig.kr(t_trig, 0.01)], buffer, bufferPhase);
			# pitch, tip, palm, gate, t_trig = BufRd.kr(nRecordedModulators, buffer, Select.kr(freeze, [delayPhase, loopPhase]), interpolation: 1);

			// build a dictionary of summed modulation signals to apply to parameters
			parameterNames.do({ |paramName|
				modulation.put(paramName, Mix.fill(modulatorNames.size, { |m|
					modulators[m] * NamedControl.kr((modulatorNames[m].asString ++ '_' ++ paramName.asString).asSymbol, 0, lag);
				}));
			});

			attack = attack * 8.pow(modulation[\attack]);
			decay = decay * 8.pow(modulation[\decay]);
			sustain = (sustain + modulation[\sustain]).clip;
			release = release * 8.pow(modulation[\decay]);
			eg = Select.kr(\egType.kr(2), [
				EnvGen.kr(Env.adsr(attack, decay, sustain, release), gate),
				EnvGen.kr(Env.asr(attack, 1, release), gate),
				EnvGen.kr(Env.perc(attack, release), t_trig)
			]);

			// TODO: LFO frequency randomization

			lfoAFreq = lfoAFreq * 8.pow(modulation[\lfoAFreq]);
			lfoA = Select.kr(lfoAType, [
				SinOsc.kr(lfoAFreq),
				LFTri.kr(lfoAFreq),
				LFSaw.kr(lfoAFreq),
				LFNoise1.kr(lfoAFreq),
				LFNoise0.kr(lfoAFreq)
			]);

			lfoBFreq = lfoBFreq * 8.pow(modulation[\lfoBFreq]);
			lfoB = Select.kr(lfoBType, [
				SinOsc.kr(lfoBFreq),
				LFTri.kr(lfoBFreq),
				LFSaw.kr(lfoBFreq),
				LFNoise1.kr(lfoBFreq),
				LFNoise0.kr(lfoBFreq)
			]);

			// this weird-looking LinSelectX pattern scales modulation signals so that
			// final parameter values (base + modulation) can always reach [-1, 1]
			tuneA    = LinSelectX.kr(1 + modulation[\tuneA],    [-1, tuneA.lag(lag),    1 ]);
			tuneB    = LinSelectX.kr(1 + modulation[\tuneB],    [-1, tuneB.lag(lag),    1 ]);
			fmIndex  = LinSelectX.kr(1 + modulation[\fmIndex],  [-1, fmIndex.lag(lag),  1 ]);
			fbB      = LinSelectX.kr(1 + modulation[\fbB],      [-1, fbB.lag(lag),      1 ]);
			opDetune = LinSelectX.kr(1 + modulation[\opDetune], [-1, opDetune.cubed.lag(lag), 1 ]);
			opMix    = LinSelectX.kr(1 + modulation[\opMix],    [-1, opMix.lag(lag),    1 ]);
			foldGain = LinSelectX.kr(1 + modulation[\foldGain], [-1, foldGain.lag(lag), 1 ]);
			lpgTone  = LinSelectX.kr(1 + modulation[\lpgTone],  [-1, lpgTone.lag(lag),  1 ]);
			pan      = LinSelectX.kr(1 + modulation[\pan],      [-1, pan.lag(lag),      1 ]);

			// now we're done with the modulation matrix

			LocalOut.kr([pitch, tip, palm, tip - palm, eg, lfoA, lfoB]);

			// slew tip for direct control of amplitude -- otherwise there will be audible steppiness
			tip = Lag.kr(tip, 0.05);
			amp = (Select.kr(ampMode, [
				tip,
				tip * eg,
				eg * -6.dbamp
			]) * (1 + modulation[\amp])).clip(0, 1);
			// scaled version of amp that allows env to fully open the LPG filter
			lpgOpenness = amp * Select.kr((ampMode == 2).asInteger, [1, 6.dbamp]).lag;

			pitch = pitch + modulation[\pitch] + tune;

			// send control values to bus for polling
			Out.kr(\voiceStateBus.ir, [amp, pitch, t_trig, lfoA > 0, lfoB > 0]);

			// TODO: why can't I use MovingAverage.kr here to get a linear slew?!
			// if I try that, SC seems to just hang forever, no error message
			pitch = Lag.kr(pitch, pitchSlew);

			hz = 2.pow(pitch + octave) * In.kr(baseFreqBus);
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
			voiceOutput = LinXFade2.ar(opA, opB, opMix);
			voiceOutput = (foldGain.linexp(-1, 1, 1, 27) * voiceOutput).fold2;
			// filter LPG-style
			voiceOutput = Select.ar(\lpgOn.kr(1), [
				voiceOutput,
				RLPF.ar(
					voiceOutput,
					lpgOpenness.lincurve(
						0, 1,
						lpgTone.lincurve(0, 1, 20, 20000, 4), lpgTone.lincurve(-1, 0, 20, 20000, 4),
						\lpgCurve.kr(3)
					),
					\lpgRQ.kr(0.9)
				)
			]);
			// scale by amplitude control value
			voiceOutput = voiceOutput * amp;

			// filter and write to main outs
			voiceOutput = HPF.ar(voiceOutput, hpCutoff.lag(lag));
			// TODO: stereo pan!
			Out.ar(context.out_b, Pan2.ar(voiceOutput * Lag.kr(outLevel, 0.05), pan));
		}).add;

		replyDef = SynthDef.new(\reply, {
			arg selectedVoice = 0,
				pollingLFO = 0;
			nVoices.do({ |v|
				var isSelected = BinaryOpUGen('==', selectedVoice, v);
				var state = In.kr(voiceStateBuses[v], 5);
				SendReply.kr(Impulse.kr(\replyRate.ir(10)) + state[2], '/voiceState', [v, state[0], state[1], state[2]]);
				SendReply.kr(Changed.kr(state[3]).abs * isSelected * BinaryOpUGen('==', pollingLFO, 1), '/lfoGate', [v, 0, state[3]]);
				SendReply.kr(Changed.kr(state[4]).abs * isSelected * BinaryOpUGen('==', pollingLFO, 2), '/lfoGate', [v, 1, state[4]]);
			});
		}).add;

		// TODO: master bus FX like saturation, decimation...?

		context.server.sync;

		baseFreqBus.setSynchronous(60.midicps);

		voiceSynths = Array.fill(nVoices, {
			arg i;
			("creating voice #" ++ i).postln;
			Synth.new(\line, [
				\voiceIndex, i,
				\buffer, controlBuffers[i],
				\delay, i * 0.2,
				\voiceStateBus, voiceStateBuses[i],
			], context.og, \addToTail); // "output" group
		});

		replySynth = Synth.new(\reply, [ \replyRate, 10 ], context.og, \addToTail);

		polls = Array.fill(nVoices, {
			arg i;
			i = i + 1;
			[
				this.addPoll(("instant_pitch_" ++ i).asSymbol, periodic: false),
				this.addPoll(("pitch_" ++ i).asSymbol, periodic: false),
				this.addPoll(("amp_" ++ i).asSymbol, periodic: false),
				this.addPoll(("lfoA_gate_" ++ i).asSymbol, periodic: false),
				this.addPoll(("lfoB_gate_" ++ i).asSymbol, periodic: false)
			];
		});

		voiceStateReplyFunc = OSCFunc({
			arg msg;
			// msg looks like [ '/voiceState', ??, -1, voiceIndex, amp, pitch, highPriorityUpdate ]
			polls[msg[3]][2].update(msg[4]);
			if(msg[6] == 1, {
				polls[msg[3]][0].update(msg[5]);
			}, {
				polls[msg[3]][1].update(msg[5]);
			});
		}, path: '/voiceState', srcID: context.server.addr);

		lfoGateReplyFunc = OSCFunc({
			arg msg;
			// msg looks like [ '/lfoGate', ??, -1, voiceIndex, lfoIndex, state ]
			polls[msg[3]][msg[4] + 3].update(msg[5]);
		}, path: '/lfoGate', srcID: context.server.addr);

		this.addCommand(\select_voice, "i", {
			arg msg;
			replySynth.set(\selectedVoice, msg[1] - 1);
		});

		this.addCommand(\poll_lfo, "i", {
			arg msg;
			replySynth.set(\pollingLFO, msg[1]);
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

		this.addCommand(\gate, "ii", {
			arg msg;
			var synth = voiceSynths[msg[1] - 1];
			var value = msg[2];
			synth.set(\gate, value, \t_trig, value);
		});

		voiceDef.allControlNames.do({ |control|
			var controlName = control.name;
			if(controlName !== \gate, {
				var signature = if([ \amp_mode, \octave ].includes(controlName), "ii", "if");
				this.addCommand(controlName, signature, { |msg|
					voiceSynths[msg[1] - 1].set(controlName, msg[2]);
				});
			});
		});
	}

	free {
		replySynth.free;
		voiceSynths.do({ |synth| synth.free });
		controlBuffers.do({ |buffer| buffer.free });
		voiceStateReplyFunc.free;
		lfoGateReplyFunc.free;
	}
}
