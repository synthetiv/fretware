Engine_Cule : CroneEngine {

	classvar nVoices = 7;
	classvar nModulators = 7;
	classvar nRecordedModulators = 5;
	classvar maxLoopTime = 16;

	var fmRatios;
	var nRatios;

	var baseFreqBus;
	var controlBuffers;
	var voiceSynths;
	var synthOutBuses;
	var polls;
	var replyFunc;

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

		// frequency ratios used by the two FM operators of each voice
		// declared as one array, but stored as two arrays, one with odd and one with even
		// members of the original; this allows operators to crossfade between two ratios
		// (see harmonicOsc function)
		fmRatios = [1/4, 1/3, 1/2, 1, 2, 4, 7, 8].clump(2).flop;
		nRatios = fmRatios.flatten.size;

		baseFreqBus = Bus.control(context.server);

		// direct outs from audio synths, to be mixed by each synth into their own FM inputs 
		synthOutBuses = Array.fill(nVoices, {
			Bus.audio(context.server);
		});

		SynthDef.new(\line, {

			arg voiceIndex,
				buffer,
				outBus,
				pitch = 0,
				gate = 0,
				t_trig = 0,
				tip = 0,
				palm = 0,
				foot = 0,
				ampMode = 0, // 0 = tip only; 1 = tip * AR; 2 = ADSR
				delay = 0,
				freeze = 0,
				t_loopReset = 0,
				loopLength = 0.3,
				loopPosition = 0,
				loopRateScale = 1,

				tune = 0,
				pitchSlew = 0.01,
				attack = 0.01,
				decay = 0.1,
				sustain = 0.8,
				release = 0.3,
				lfoAType = 0,
				lfoAFreq = 0.9,
				lfoAAmount = 1,
				lfoBType = 0,
				lfoBFreq = 1.1,
				lfoBAmount = 1,
				oscType = 1,
				tuneA = 0,
				tuneB = 0.3,
				fmIndex = 0,
				fbB = 0,
				opDetune = 0,
				opMix = 0,
				foldGain = 0,
				foldBias = 0,
				lag = 0.1,

				octave = 0,
				detuneType = 0.2,
				fadeSize = 0.5,
				fmCutoff = 12000,
				lpCutoff = 23000,
				hpCutoff = 16,
				outLevel = 0.2,

				tip_tuneA = 0,
				tip_tuneB = 0,
				tip_fmIndex = 0,
				tip_fbB = 0,
				tip_opDetune = 0,
				tip_opMix = 0,
				tip_foldGain = 0,
				tip_foldBias = 0,
				// TODO: include EG times as mod destinations
				tip_lfoAFreq = 0,
				tip_lfoAAmount = 0,
				tip_lfoBFreq = 0,
				tip_lfoBAmount = 0,

				palm_tuneA = 0,
				palm_tuneB = 0,
				palm_fmIndex = 0,
				palm_fbB = 0,
				palm_opDetune = 0,
				palm_opMix = 0,
				palm_foldGain = 0,
				palm_foldBias = 0,
				palm_lfoAFreq = 0,
				palm_lfoAAmount = 0,
				palm_lfoBFreq = 0,
				palm_lfoBAmount = 0,

				foot_tuneA = 0,
				foot_tuneB = 0,
				foot_fmIndex = 0,
				foot_fbB = 0,
				foot_opDetune = 0,
				foot_opMix = 0,
				foot_foldGain = 0,
				foot_foldBias = 0,
				foot_lfoAFreq = 0,
				foot_lfoAAmount = 0,
				foot_lfoBFreq = 0,
				foot_lfoBAmount = 0,

				eg_pitch = 0,
				eg_tuneA = 0,
				eg_tuneB = 0,
				eg_fmIndex = 0,
				eg_fbB = 0,
				eg_opDetune = 0,
				eg_opMix = 0,
				eg_foldGain = 0,
				eg_foldBias = 0,
				eg_lfoAFreq = 0,
				eg_lfoAAmount = 0,
				eg_lfoBFreq = 0,
				eg_lfoBAmount = 0,

				lfoA_pitch = 0,
				lfoA_amp = 0,
				lfoA_tuneA = 0,
				lfoA_tuneB = 0,
				lfoA_fmIndex = 0,
				lfoA_fbB = 0,
				lfoA_opDetune = 0,
				lfoA_opMix = 0,
				lfoA_foldGain = 0,
				lfoA_foldBias = 0,
				lfoA_lfoBFreq = 0,
				lfoA_lfoBAmount = 0,

				lfoB_pitch = 0,
				lfoB_amp = 0,
				lfoB_tuneA = 0,
				lfoB_tuneB = 0,
				lfoB_fmIndex = 0,
				lfoB_fbB = 0,
				lfoB_opDetune = 0,
				lfoB_opMix = 0,
				lfoB_foldGain = 0,
				lfoB_foldBias = 0,
				lfoB_lfoAFreq = 0,
				lfoB_lfoAAmount = 0,

				pitch_tuneA = -0.1,
				pitch_tuneB = -0.1,
				pitch_fmIndex = 0,
				pitch_fbB = 0,
				pitch_opDetune = 0,
				pitch_opMix = 0,
				pitch_foldGain = 0,
				pitch_foldBias = 0,
				// TODO: pitch -> LFO freqs and amounts
				// TODO: pitch -> FM amounts from other voices
				// TODO: EG -> LFO freqs and amounts, and vice versa

				voice1_fm = 0,
				voice2_fm = 0,
				voice3_fm = 0,
				voice4_fm = 0,
				voice5_fm = 0,
				voice6_fm = 0,
				voice7_fm = 0,

				egGateTrig = 0,
				trigLength = 0.01,
				replyRate = 10;

			var bufferLength, bufferPhase, delayPhase,
				loopStart, loopPhase, loopTrigger, loopOffset,
				eg, lfoA, lfoB,
				hz, detuneLin, detuneExp,
				fmInput, opB, fmMix, opA,
				voiceOutput;

			// this feedback loop is needed in order for modulators to modulate one another
			var modulators = LocalIn.kr(nModulators);

			var gateOrTrig = Select.kr(egGateTrig, [
				gate,
				Trig.kr(t_trig, trigLength),
			]);

			var ar = EnvGen.kr(
				Env.asr(attack, 1, release),
				gateOrTrig
			);

			var amp = (Select.kr(ampMode, [
				modulators[1],
				modulators[1] * ar,
				modulators[4]
			]) * (1 + Mix(modulators[4..5] * [lfoA_amp, lfoB_amp]))).max(0);

			var bufferRateScale = 0.5,
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
			BufWr.kr([pitch, tip, palm, foot, amp], buffer, bufferPhase);
			# pitch, tip, palm, foot, amp = BufRd.kr(nRecordedModulators, buffer, Select.kr(freeze, [delayPhase, loopPhase]), interpolation: 1);

			// slew direct control
			tip      = Lag.kr(tip,      lag);
			palm     = Lag.kr(palm,     lag);
			foot     = Lag.kr(foot,     lag);
			tuneA    = Lag.kr(tuneA,    lag);
			tuneB    = Lag.kr(tuneB,    lag);
			fmIndex  = Lag.kr(fmIndex,  lag);
			fbB      = Lag.kr(fbB,      lag);
			opDetune = Lag.kr(opDetune, lag);
			opMix    = Lag.kr(opMix,    lag);
			foldGain = Lag.kr(foldGain, lag);
			foldBias = Lag.kr(foldBias, lag);

			eg = EnvGen.kr(
				Env.adsr(attack, decay, sustain, release),
				gateOrTrig,
				-6.dbamp
			);

			lfoAFreq = lfoAFreq * 2.pow(Mix(modulators * [0, tip_lfoAFreq, palm_lfoAFreq, foot_lfoAFreq, eg_lfoAFreq, 0, lfoB_lfoAFreq]));
			lfoAAmount = lfoAAmount + Mix(modulators * [0, tip_lfoAAmount, palm_lfoAAmount, foot_lfoAAmount, eg_lfoAAmount, 0, lfoB_lfoAAmount]);
			lfoA = lfoAAmount * Select.kr(lfoAType, [
				SinOsc.kr(lfoAFreq),
				LFTri.kr(lfoAFreq),
				LFSaw.kr(lfoAFreq),
				LFNoise1.kr(lfoAFreq),
				LFNoise0.kr(lfoAFreq)
			]);

			lfoBFreq = lfoBFreq * 2.pow(Mix(modulators * [0, tip_lfoBFreq, palm_lfoBFreq, foot_lfoBFreq, eg_lfoBFreq, lfoA_lfoBFreq, 0]));
			lfoBAmount = lfoBAmount + Mix(modulators * [0, tip_lfoBAmount, palm_lfoBAmount, foot_lfoBAmount, eg_lfoBAmount, lfoA_lfoBAmount, 0]);
			lfoB = lfoBAmount * Select.kr(lfoBType, [
				SinOsc.kr(lfoBFreq),
				LFTri.kr(lfoBFreq),
				LFSaw.kr(lfoBFreq),
				LFNoise1.kr(lfoBFreq),
				LFNoise0.kr(lfoBFreq)
			]);

			LocalOut.kr([pitch, tip, palm, foot, eg, lfoA, lfoB]);

			pitch = pitch + tune + Mix([eg, lfoA, lfoB] * [eg_pitch, lfoA_pitch, lfoB_pitch]);

			// send control values to polls, both regularly (replyRate Hz) and immediately when gate goes high or when voice loops
			SendReply.kr(trig: Impulse.kr(replyRate) + Changed.kr(pitch, 0.04), cmdName: '/voicePitchAmp', values: [voiceIndex, pitch, amp]);

			// TODO: why can't I use MovingAverage.kr here to get a linear slew?!
			// if I try that, SC seems to just hang forever, no error message
			pitch = Lag.kr(pitch, pitchSlew);

			// TODO: clip these values in the audio synth, not here
			tuneA = (tuneA + Mix(modulators * [pitch_tuneA, tip_tuneA, palm_tuneA,
						foot_tuneA, eg_tuneA, lfoA_tuneA, lfoB_tuneA]));
			tuneB = (tuneB + Mix(modulators * [pitch_tuneB, tip_tuneB, palm_tuneB,
						foot_tuneB, eg_tuneB, lfoA_tuneB, lfoB_tuneB]));
			fmIndex = (fmIndex + Mix(modulators * [pitch_fmIndex, tip_fmIndex,
						palm_fmIndex, foot_fmIndex, eg_fmIndex,
						lfoA_fmIndex, lfoB_fmIndex]));
			fbB = (fbB + Mix(modulators * [pitch_fbB, tip_fbB, palm_fbB, foot_fbB,
						eg_fbB, lfoA_fbB, lfoB_fbB]));
			opDetune = (opDetune + Mix(modulators * [pitch_opDetune, tip_opDetune,
						palm_opDetune, foot_opDetune, eg_opDetune,
						lfoA_opDetune, lfoB_opDetune]));
			opMix = (opMix + Mix(modulators * [pitch_opMix, tip_opMix, palm_opMix,
						foot_opMix, eg_opMix, lfoA_opMix, lfoB_opMix]));
			foldGain = (foldGain + Mix(modulators * [pitch_foldGain, tip_foldGain,
						palm_foldGain, foot_foldGain, eg_foldGain,
						lfoA_foldGain, lfoB_foldGain]));
			foldBias = (foldBias + Mix(modulators * [pitch_foldBias, tip_foldBias,
						palm_foldBias, foot_foldBias, eg_foldBias,
						lfoA_foldBias, lfoB_foldBias]));

			// calculate FM mix to feed to operator A
			fmInput = Mix(InFeedback.ar(synthOutBuses) * [voice1_fm, voice2_fm,
					voice3_fm, voice4_fm, voice5_fm, voice6_fm, voice7_fm]);

			hz = 2.pow(pitch + octave) * In.kr(baseFreqBus);
			detuneLin = opDetune * 10 * detuneType;
			detuneExp = (opDetune / 10 * (1 - detuneType)).midiratio;
			opB = this.harmonicOsc(
				SinOscFB,
				hz * detuneExp + detuneLin,
				tuneB,
				fadeSize,
				fbB.linexp(-1, 1, 0.01, 3)
			);
			fmMix = fmInput + (opB * fmIndex.linexp(-1, 1, 0.01, 10pi));
			fmMix = LPF.ar(fmMix, fmCutoff).mod(2pi);
			opA = this.harmonicOsc(
				SinOsc,
				hz / detuneExp - detuneLin,
				tuneA,
				fadeSize,
				fmMix
			);
			voiceOutput = LinXFade2.ar(opA, opB, opMix);
			voiceOutput = SinOsc.ar(0, (foldGain.linexp(-1, 1, 0.1, 10pi) * voiceOutput +
						foldBias.linlin(-1, 1, 0, pi / 2)).clip2(2pi));
			// compensate for DC offset introduced by fold bias
			voiceOutput = LeakDC.ar(voiceOutput);
			// compensate for lost amplitude due to bias (a fully rectified wave is half the amplitude of the original)
			voiceOutput = voiceOutput * foldBias.linlin(-1, 1, 1, 2);
			// scale by amplitude control value
			voiceOutput = voiceOutput * amp;

			// write to bus for FM
			Out.ar(outBus, voiceOutput);

			// filter and write to main outs
			voiceOutput = LPF.ar(HPF.ar(voiceOutput, hpCutoff), lpCutoff);
			// TODO: stereo pan!
			Out.ar(context.out_b, voiceOutput ! 2 * Lag.kr(outLevel, 0.05));
		}).add;

		// TODO: master bus FX like saturation, decimation...?

		context.server.sync;

		baseFreqBus.setSynchronous(60.midicps);

		controlBuffers = Array.fill(nVoices, {
			Buffer.alloc(context.server, context.server.sampleRate / context.server.options.blockSize * maxLoopTime, nRecordedModulators);
		});
		voiceSynths = Array.fill(nVoices, {
			arg i;
			Synth.new(\line, [
				\voiceIndex, i,
				\buffer, controlBuffers[i],
				\delay, i * 0.2,
				\outBus, synthOutBuses[i],
			], context.og, \addToTail); // "output" group
		});
		polls = Array.fill(nVoices, {
			arg i;
			i = i + 1;
			[
				this.addPoll(("pitch_" ++ i).asSymbol, periodic: false),
				this.addPoll(("amp_" ++ i).asSymbol, periodic: false)
			];
		});
		replyFunc = OSCFunc({
			arg msg;
			// msg looks like [ '/voicePitchAmp', ??, -1, index, pitch, amp ]
			polls[msg[3]][0].update(msg[4]);
			polls[msg[3]][1].update(msg[5]);
		}, path: '/voicePitchAmp', srcID: context.server.addr);

		this.addCommand(\base_freq, "f", {
			arg msg;
			baseFreqBus.setSynchronous(msg[1]);
		});

		this.addCommand(\delay, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\delay, msg[2]);
		});

		this.addCommand(\set_loop, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(
				\loopLength, msg[2],
				\loopRateScale, 1,
				\freeze, 1
			);
		});

		this.addCommand(\reset_loop_phase, "i", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\t_loopReset, 1);
		});

		this.addCommand(\clear_loop, "i", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\freeze, 0);
		});

		this.addCommand(\loop_position, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\loopPosition, msg[2]);
		});

		this.addCommand(\loop_rate_scale, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\loopRateScale, msg[2]);
		});

		this.addCommand(\pitch, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\pitch, msg[2]);
		});

		this.addCommand(\gate, "ii", {
			arg msg;
			var synth = voiceSynths[msg[1] - 1];
			var value = msg[2];
			synth.set(\gate, value);
			if(value == 1, { synth.set(\t_trig, 1); });
		});

		this.addCommand(\amp_mode, "ii", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\ampMode, msg[2] - 1);
		});

		this.addCommand(\pitch_slew, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\pitchSlew, msg[2]);
		});

		this.addCommand(\tune, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\tune, msg[2]);
		});

		this.addCommand(\tip, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\tip, msg[2]);
		});

		this.addCommand(\palm, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\palm, msg[2]);
		});

		this.addCommand(\foot, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\foot, msg[2]);
		});

		this.addCommand(\lfo_a_type, "ii", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoAType, msg[2] - 1);
		});
		this.addCommand(\lfo_a_freq, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoAFreq, msg[2]);
		});
		this.addCommand(\lfo_a_amount, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoAAmount, msg[2]);
		});

		this.addCommand(\lfo_b_type, "ii", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoBType, msg[2] - 1);
		});
		this.addCommand(\lfo_b_freq, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoBFreq, msg[2]);
		});
		this.addCommand(\lfo_b_amount, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoBAmount, msg[2]);
		});

		this.addCommand(\attack, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\attack, msg[2]);
		});

		this.addCommand(\decay, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\decay, msg[2]);
		});

		this.addCommand(\sustain, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\sustain, msg[2]);
		});

		this.addCommand(\release, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\release, msg[2]);
		});

		this.addCommand(\tune_a, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\tuneA, msg[2]);
		});

		this.addCommand(\tune_b, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\tuneB, msg[2]);
		});

		this.addCommand(\fm_index, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\fmIndex, msg[2]);
		});

		this.addCommand(\fb_b, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\fbB, msg[2]);
		});

		this.addCommand(\op_detune, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\opDetune, msg[2]);
		});

		this.addCommand(\op_mix, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\opMix, msg[2]);
		});

		this.addCommand(\fold_gain, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\foldGain, msg[2]);
		});

		this.addCommand(\fold_bias, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\foldBias, msg[2]);
		});

		this.addCommand(\lag, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lag, msg[2]);
		});

		// TODO: use loops for this, this is ugly

		this.addCommand(\tip_tune_a, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\tip_tuneA, msg[2]);
		});
		this.addCommand(\tip_tune_b, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\tip_tuneB, msg[2]);
		});
		this.addCommand(\tip_fm_index, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\tip_fmIndex, msg[2]);
		});
		this.addCommand(\tip_fb_b, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\tip_fbB, msg[2]);
		});
		this.addCommand(\tip_op_detune, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\tip_opDetune, msg[2]);
		});
		this.addCommand(\tip_op_mix, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\tip_opMix, msg[2]);
		});
		this.addCommand(\tip_fold_gain, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\tip_foldGain, msg[2]);
		});
		this.addCommand(\tip_fold_bias, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\tip_foldBias, msg[2]);
		});
		this.addCommand(\tip_lfo_a_freq, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\tip_lfoAFreq, msg[2]);
		});
		this.addCommand(\tip_lfo_a_amount, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\tip_lfoAAmount, msg[2]);
		});
		this.addCommand(\tip_lfo_b_freq, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\tip_lfoBFreq, msg[2]);
		});
		this.addCommand(\tip_lfo_b_amount, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\tip_lfoBAmount, msg[2]);
		});

		this.addCommand(\palm_tune_a, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\palm_tuneA, msg[2]);
		});
		this.addCommand(\palm_tune_b, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\palm_tuneB, msg[2]);
		});
		this.addCommand(\palm_fm_index, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\palm_fmIndex, msg[2]);
		});
		this.addCommand(\palm_fb_b, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\palm_fbB, msg[2]);
		});
		this.addCommand(\palm_op_detune, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\palm_opDetune, msg[2]);
		});
		this.addCommand(\palm_op_mix, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\palm_opMix, msg[2]);
		});
		this.addCommand(\palm_fold_gain, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\palm_foldGain, msg[2]);
		});
		this.addCommand(\palm_fold_bias, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\palm_foldBias, msg[2]);
		});
		this.addCommand(\palm_lfo_a_freq, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\palm_lfoAFreq, msg[2]);
		});
		this.addCommand(\palm_lfo_a_amount, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\palm_lfoAAmount, msg[2]);
		});
		this.addCommand(\palm_lfo_b_freq, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\palm_lfoBFreq, msg[2]);
		});
		this.addCommand(\palm_lfo_b_amount, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\palm_lfoBAmount, msg[2]);
		});

		this.addCommand(\foot_tune_a, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\foot_tuneA, msg[2]);
		});
		this.addCommand(\foot_tune_b, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\foot_tuneB, msg[2]);
		});
		this.addCommand(\foot_fm_index, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\foot_fmIndex, msg[2]);
		});
		this.addCommand(\foot_fb_b, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\foot_fbB, msg[2]);
		});
		this.addCommand(\foot_op_detune, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\foot_opDetune, msg[2]);
		});
		this.addCommand(\foot_op_mix, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\foot_opMix, msg[2]);
		});
		this.addCommand(\foot_fold_gain, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\foot_foldGain, msg[2]);
		});
		this.addCommand(\foot_fold_bias, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\foot_foldBias, msg[2]);
		});
		this.addCommand(\foot_lfo_a_freq, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\foot_lfoAFreq, msg[2]);
		});
		this.addCommand(\foot_lfo_a_amount, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\foot_lfoAAmount, msg[2]);
		});
		this.addCommand(\foot_lfo_b_freq, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\foot_lfoBFreq, msg[2]);
		});
		this.addCommand(\foot_lfo_b_amount, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\foot_lfoBAmount, msg[2]);
		});

		this.addCommand(\eg_pitch, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\eg_pitch, msg[2]);
		});
		this.addCommand(\eg_tune_a, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\eg_tuneA, msg[2]);
		});
		this.addCommand(\eg_tune_b, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\eg_tuneB, msg[2]);
		});
		this.addCommand(\eg_fm_index, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\eg_fmIndex, msg[2]);
		});
		this.addCommand(\eg_fb_b, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\eg_fbB, msg[2]);
		});
		this.addCommand(\eg_op_detune, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\eg_opDetune, msg[2]);
		});
		this.addCommand(\eg_op_mix, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\eg_opMix, msg[2]);
		});
		this.addCommand(\eg_fold_gain, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\eg_foldGain, msg[2]);
		});
		this.addCommand(\eg_fold_bias, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\eg_foldBias, msg[2]);
		});
		this.addCommand(\eg_lfo_a_freq, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\eg_lfoAFreq, msg[2]);
		});
		this.addCommand(\eg_lfo_a_amount, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\eg_lfoAAmount, msg[2]);
		});
		this.addCommand(\eg_lfo_b_freq, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\eg_lfoBFreq, msg[2]);
		});
		this.addCommand(\eg_lfo_b_amount, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\eg_lfoBAmount, msg[2]);
		});

		this.addCommand(\lfo_a_pitch, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoA_pitch, msg[2]);
		});
		this.addCommand(\lfo_a_amp, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoA_amp, msg[2]);
		});
		this.addCommand(\lfo_a_tune_a, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoA_tuneA, msg[2]);
		});
		this.addCommand(\lfo_a_tune_b, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoA_tuneB, msg[2]);
		});
		this.addCommand(\lfo_a_fm_index, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoA_fmIndex, msg[2]);
		});
		this.addCommand(\lfo_a_fb_b, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoA_fbB, msg[2]);
		});
		this.addCommand(\lfo_a_op_detune, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoA_opDetune, msg[2]);
		});
		this.addCommand(\lfo_a_op_mix, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoA_opMix, msg[2]);
		});
		this.addCommand(\lfo_a_fold_gain, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoA_foldGain, msg[2]);
		});
		this.addCommand(\lfo_a_fold_bias, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoA_foldBias, msg[2]);
		});
		this.addCommand(\lfo_a_lfo_b_freq, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoA_lfoBFreq, msg[2]);
		});
		this.addCommand(\lfo_a_lfo_b_amount, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoA_lfoBAmount, msg[2]);
		});

		this.addCommand(\lfo_b_pitch, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoB_pitch, msg[2]);
		});
		this.addCommand(\lfo_b_amp, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoB_amp, msg[2]);
		});
		this.addCommand(\lfo_b_tune_a, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoB_tuneA, msg[2]);
		});
		this.addCommand(\lfo_b_tune_b, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoB_tuneB, msg[2]);
		});
		this.addCommand(\lfo_b_fm_index, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoB_fmIndex, msg[2]);
		});
		this.addCommand(\lfo_b_fb_b, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoB_fbB, msg[2]);
		});
		this.addCommand(\lfo_b_op_detune, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoB_opDetune, msg[2]);
		});
		this.addCommand(\lfo_b_op_mix, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoB_opMix, msg[2]);
		});
		this.addCommand(\lfo_b_fold_gain, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoB_foldGain, msg[2]);
		});
		this.addCommand(\lfo_b_fold_bias, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoB_foldBias, msg[2]);
		});
		this.addCommand(\lfo_b_lfo_a_freq, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoB_lfoAFreq, msg[2]);
		});
		this.addCommand(\lfo_b_lfo_a_amount, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lfoB_lfoAAmount, msg[2]);
		});

		this.addCommand(\pitch_tune_a, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\pitch_tuneA, msg[2]);
		});
		this.addCommand(\pitch_tune_b, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\pitch_tuneB, msg[2]);
		});
		this.addCommand(\pitch_fm_index, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\pitch_fmIndex, msg[2]);
		});
		this.addCommand(\pitch_fb_b, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\pitch_fbB, msg[2]);
		});
		this.addCommand(\pitch_op_detune, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\pitch_opDetune, msg[2]);
		});
		this.addCommand(\pitch_op_mix, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\pitch_opMix, msg[2]);
		});
		this.addCommand(\pitch_fold_gain, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\pitch_foldGain, msg[2]);
		});
		this.addCommand(\pitch_fold_bias, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\pitch_foldBias, msg[2]);
		});

		this.addCommand(\voice1_fm, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\voice1_fm, msg[2]);
		});
		this.addCommand(\voice2_fm, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\voice2_fm, msg[2]);
		});
		this.addCommand(\voice3_fm, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\voice3_fm, msg[2]);
		});
		this.addCommand(\voice4_fm, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\voice4_fm, msg[2]);
		});
		this.addCommand(\voice5_fm, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\voice5_fm, msg[2]);
		});
		this.addCommand(\voice6_fm, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\voice6_fm, msg[2]);
		});
		this.addCommand(\voice7_fm, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\voice7_fm, msg[2]);
		});

		this.addCommand(\octave, "ii", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\octave, msg[2]);
		});

		this.addCommand(\detune_type, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\detuneType, msg[2]);
		});

		this.addCommand(\fade_size, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\fadeSize, msg[2]);
		});

		this.addCommand(\fm_cutoff, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\fmCutoff, msg[2]);
		});

		this.addCommand(\lp_cutoff, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\lpCutoff, msg[2]);
		});
		this.addCommand(\hp_cutoff, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\hpCutoff, msg[2]);
		});

		this.addCommand(\out_level, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\outLevel, msg[2]);
		});

		this.addCommand(\reply_rate, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\replyRate, msg[2]);
		});
		this.addCommand(\eg_gate_trig, "ii", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\egGateTrig, msg[2]);
		});
		this.addCommand(\trig_length, "if", {
			arg msg;
			voiceSynths[msg[1] - 1].set(\trigLength, msg[2]);
		});
	}

	free {
		voiceSynths.do({ |synth| synth.free });
		controlBuffers.do({ |buffer| buffer.free });
		replyFunc.free;
	}
}
