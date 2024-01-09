Engine_Cule : CroneEngine {

	classvar nVoices = 7;
	classvar nModulators = 7;
	classvar nParams = 8;
	classvar nRecordedModulators = 5;
	classvar maxLoopTime = 16;

	var fmRatios;
	var nRatios;

	var baseFreqBus;
	var controlBuffers;
	var controlSynths;
	var synthOutBuses;
	var fmBuses;
	var controlBuses;
	var audioSynths;
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

		// direct outs from audio synths, to be mixed by control synths into fm signals
		synthOutBuses = Array.fill(nVoices, {
			Bus.audio(context.server);
		});

		// buses for audio rate FM signals: mixed by control synths, applied by audio synths
		fmBuses = Array.fill(nVoices, {
			Bus.audio(context.server);
		});

		// buses for sending data from control synths to hot-swappable audio synths:
		// frequency, amp, and four timbre parameters
		controlBuses = Array.fill(nVoices, {
			Bus.control(context.server, nParams + 2);
		});

		SynthDef.new(\line, {

			arg voiceIndex,
				buffer,
				fmBus,
				controlBus,
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
				p1 = 0,
				p2 = 0.3,
				p3 = 0,
				p4 = 0,
				p5 = 0,
				p6 = 0,
				p7 = 0,
				p8 = 0,
				lag = 0.1,

				tip_p1 = 0,
				tip_p2 = 0,
				tip_p3 = 0,
				tip_p4 = 0,
				tip_p5 = 0,
				tip_p6 = 0,
				tip_p7 = 0,
				tip_p8 = 0,
				// TODO: include EG times as mod destinations
				tip_lfoAFreq = 0,
				tip_lfoAAmount = 0,
				tip_lfoBFreq = 0,
				tip_lfoBAmount = 0,

				palm_p1 = 0,
				palm_p2 = 0,
				palm_p3 = 0,
				palm_p4 = 0,
				palm_p5 = 0,
				palm_p6 = 0,
				palm_p7 = 0,
				palm_p8 = 0,
				palm_lfoAFreq = 0,
				palm_lfoAAmount = 0,
				palm_lfoBFreq = 0,
				palm_lfoBAmount = 0,

				foot_p1 = 0,
				foot_p2 = 0,
				foot_p3 = 0,
				foot_p4 = 0,
				foot_p5 = 0,
				foot_p6 = 0,
				foot_p7 = 0,
				foot_p8 = 0,
				foot_lfoAFreq = 0,
				foot_lfoAAmount = 0,
				foot_lfoBFreq = 0,
				foot_lfoBAmount = 0,

				eg_pitch = 0,
				eg_p1 = 0,
				eg_p2 = 0,
				eg_p3 = 0,
				eg_p4 = 0,
				eg_p5 = 0,
				eg_p6 = 0,
				eg_p7 = 0,
				eg_p8 = 0,
				eg_lfoAFreq = 0,
				eg_lfoAAmount = 0,
				eg_lfoBFreq = 0,
				eg_lfoBAmount = 0,

				lfoA_pitch = 0,
				lfoA_amp = 0,
				lfoA_p1 = 0,
				lfoA_p2 = 0,
				lfoA_p3 = 0,
				lfoA_p4 = 0,
				lfoA_p5 = 0,
				lfoA_p6 = 0,
				lfoA_p7 = 0,
				lfoA_p8 = 0,
				lfoA_lfoBFreq = 0,
				lfoA_lfoBAmount = 0,

				lfoB_pitch = 0,
				lfoB_amp = 0,
				lfoB_p1 = 0,
				lfoB_p2 = 0,
				lfoB_p3 = 0,
				lfoB_p4 = 0,
				lfoB_p5 = 0,
				lfoB_p6 = 0,
				lfoB_p7 = 0,
				lfoB_p8 = 0,
				lfoB_lfoAFreq = 0,
				lfoB_lfoAAmount = 0,

				pitch_p1 = -0.1,
				pitch_p2 = -0.1,
				pitch_p3 = 0,
				pitch_p4 = 0,
				pitch_p5 = 0,
				pitch_p6 = 0,
				pitch_p7 = 0,
				pitch_p8 = 0,
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
				hz;

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
			tip  = Lag.kr(tip,  lag);
			palm = Lag.kr(palm, lag);
			foot = Lag.kr(foot, lag);
			p1   = Lag.kr(p1,   lag);
			p2   = Lag.kr(p2,   lag);
			p3   = Lag.kr(p3,   lag);
			p4   = Lag.kr(p4,   lag);
			p5   = Lag.kr(p5,   lag);
			p6   = Lag.kr(p6,   lag);
			p7   = Lag.kr(p7,   lag);
			p8   = Lag.kr(p8,   lag);

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
			p1 = (p1 + Mix(modulators * [pitch_p1, tip_p1, palm_p1, foot_p1, eg_p1, lfoA_p1, lfoB_p1]));
			p2 = (p2 + Mix(modulators * [pitch_p2, tip_p2, palm_p2, foot_p2, eg_p2, lfoA_p2, lfoB_p2]));
			p3 = (p3 + Mix(modulators * [pitch_p3, tip_p3, palm_p3, foot_p3, eg_p3, lfoA_p3, lfoB_p3]));
			p4 = (p4 + Mix(modulators * [pitch_p4, tip_p4, palm_p4, foot_p4, eg_p4, lfoA_p4, lfoB_p4]));
			p5 = (p5 + Mix(modulators * [pitch_p5, tip_p5, palm_p5, foot_p5, eg_p5, lfoA_p5, lfoB_p5]));
			p6 = (p6 + Mix(modulators * [pitch_p6, tip_p6, palm_p6, foot_p6, eg_p6, lfoA_p6, lfoB_p6]));
			p7 = (p7 + Mix(modulators * [pitch_p7, tip_p7, palm_p7, foot_p7, eg_p7, lfoA_p7, lfoB_p7]));
			p8 = (p8 + Mix(modulators * [pitch_p8, tip_p8, palm_p8, foot_p8, eg_p8, lfoA_p8, lfoB_p8]));

			// write FM mix to FM bus
			Out.ar(fmBus, Mix(InFeedback.ar(synthOutBuses) * [voice1_fm, voice2_fm, voice3_fm, voice4_fm, voice5_fm, voice6_fm, voice7_fm]));

			// write control signals to control bus
			Out.kr(controlBus, [pitch, amp, p1, p2, p3, p4, p5, p6, p7, p8]);
		}).add;

		SynthDef.new(\sine, {
			arg fmBus, controlBus, outBus, octave = 0, detuneType = 0.2, fadeSize = 0.5, fmCutoff = 12000, lpCutoff = 23000, hpCutoff = 16, outLevel = 0.2;
			var pitch, amp, tuneA, tuneB, fmIndex, feedback, detune, mix, foldGain, foldBias,
				hz, detuneLin, detuneExp, modulator, fmMix, carrier, sine;
			# pitch, amp, tuneA, tuneB, fmIndex, feedback, detune, mix, foldGain, foldBias = In.kr(controlBus, nParams + 2);
			hz = 2.pow(pitch + octave) * In.kr(baseFreqBus);
			detuneLin = detune * 10 * detuneType;
			detuneExp = (detune / 10 * (1 - detuneType)).midiratio;
			modulator = this.harmonicOsc(
				SinOscFB,
				hz * detuneExp + detuneLin,
				tuneB,
				fadeSize,
				feedback.linexp(-1, 1, 0.01, 3)
			);
			fmMix = In.ar(fmBus) + (modulator * fmIndex.linexp(-1, 1, 0.01, 10pi));
			fmMix = LPF.ar(fmMix, fmCutoff).mod(2pi);
			carrier = this.harmonicOsc(
				SinOsc,
				hz / detuneExp - detuneLin,
				tuneA,
				fadeSize,
				fmMix
			);
			sine = LinXFade2.ar(carrier, modulator, mix);
			sine = SinOsc.ar(0, (foldGain.linexp(-1, 1, 0.1, 10pi) * sine + foldBias.linlin(-1, 1, 0, pi / 2)).clip2(2pi));
			// compensate for DC offset introduced by fold bias
			sine = LeakDC.ar(sine);
			// compensate for lost amplitude due to bias (a fully rectified wave is half the amplitude of the original)
			sine = sine * foldBias.linlin(-1, 1, 1, 2);
			// scale by amplitude control value
			sine = sine * amp;

			// write to bus for FM
			Out.ar(outBus, sine);

			// filter and write to main outs
			sine = LPF.ar(HPF.ar(sine, hpCutoff), lpCutoff);
			Out.ar(context.out_b, sine ! 2 * Lag.kr(outLevel, 0.05));
		}).add;

		// TODO: master bus FX like saturation, decimation...?

		context.server.sync;

		baseFreqBus.setSynchronous(60.midicps);

		controlBuffers = Array.fill(nVoices, {
			Buffer.alloc(context.server, context.server.sampleRate / context.server.options.blockSize * maxLoopTime, nRecordedModulators);
		});
		controlSynths = Array.fill(nVoices, {
			arg i;
			Synth.new(\line, [
				\voiceIndex, i,
				\buffer, controlBuffers[i],
				\fmBus, fmBuses[i],
				\controlBus, controlBuses[i],
				\delay, i * 0.2,
			], context.og, \addToTail); // "output" group
		});
		audioSynths = Array.fill(nVoices, {
			arg i;
			Synth.new(\sine, [
				\fmBus, fmBuses[i],
				\controlBus, controlBuses[i],
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
			controlSynths[msg[1] - 1].set(\delay, msg[2]);
		});

		this.addCommand(\set_loop, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(
				\loopLength, msg[2],
				\loopRateScale, 1,
				\freeze, 1
			);
		});

		this.addCommand(\reset_loop_phase, "i", {
			arg msg;
			controlSynths[msg[1] - 1].set(\t_loopReset, 1);
		});

		this.addCommand(\clear_loop, "i", {
			arg msg;
			controlSynths[msg[1] - 1].set(\freeze, 0);
		});

		this.addCommand(\loop_position, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\loopPosition, msg[2]);
		});

		this.addCommand(\loop_rate_scale, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\loopRateScale, msg[2]);
		});

		this.addCommand(\pitch, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\pitch, msg[2]);
		});

		this.addCommand(\gate, "ii", {
			arg msg;
			var synth = controlSynths[msg[1] - 1];
			var value = msg[2];
			synth.set(\gate, value);
			if(value == 1, { synth.set(\t_trig, 1); });
		});

		this.addCommand(\amp_mode, "ii", {
			arg msg;
			controlSynths[msg[1] - 1].set(\ampMode, msg[2] - 1);
		});

		this.addCommand(\pitch_slew, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\pitchSlew, msg[2]);
		});

		this.addCommand(\tune, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\tune, msg[2]);
		});

		this.addCommand(\tip, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\tip, msg[2]);
		});

		this.addCommand(\palm, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\palm, msg[2]);
		});

		this.addCommand(\foot, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\foot, msg[2]);
		});

		this.addCommand(\lfo_a_type, "ii", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoAType, msg[2] - 1);
		});
		this.addCommand(\lfo_a_freq, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoAFreq, msg[2]);
		});
		this.addCommand(\lfo_a_amount, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoAAmount, msg[2]);
		});

		this.addCommand(\lfo_b_type, "ii", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoBType, msg[2] - 1);
		});
		this.addCommand(\lfo_b_freq, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoBFreq, msg[2]);
		});
		this.addCommand(\lfo_b_amount, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoBAmount, msg[2]);
		});

		this.addCommand(\attack, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\attack, msg[2]);
		});

		this.addCommand(\decay, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\decay, msg[2]);
		});

		this.addCommand(\sustain, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\sustain, msg[2]);
		});

		this.addCommand(\release, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\release, msg[2]);
		});

		this.addCommand(\p1, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\p1, msg[2]);
		});

		this.addCommand(\p2, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\p2, msg[2]);
		});

		this.addCommand(\p3, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\p3, msg[2]);
		});

		this.addCommand(\p4, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\p4, msg[2]);
		});

		this.addCommand(\p5, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\p5, msg[2]);
		});

		this.addCommand(\p6, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\p6, msg[2]);
		});

		this.addCommand(\p7, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\p7, msg[2]);
		});

		this.addCommand(\p8, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\p8, msg[2]);
		});

		this.addCommand(\lag, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lag, msg[2]);
		});

		// TODO: use loops for this, this is ugly

		this.addCommand(\tip_p1, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\tip_p1, msg[2]);
		});
		this.addCommand(\tip_p2, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\tip_p2, msg[2]);
		});
		this.addCommand(\tip_p3, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\tip_p3, msg[2]);
		});
		this.addCommand(\tip_p4, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\tip_p4, msg[2]);
		});
		this.addCommand(\tip_p5, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\tip_p5, msg[2]);
		});
		this.addCommand(\tip_p6, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\tip_p6, msg[2]);
		});
		this.addCommand(\tip_p7, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\tip_p7, msg[2]);
		});
		this.addCommand(\tip_p8, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\tip_p8, msg[2]);
		});
		this.addCommand(\tip_lfo_a_freq, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\tip_lfoAFreq, msg[2]);
		});
		this.addCommand(\tip_lfo_a_amount, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\tip_lfoAAmount, msg[2]);
		});
		this.addCommand(\tip_lfo_b_freq, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\tip_lfoBFreq, msg[2]);
		});
		this.addCommand(\tip_lfo_b_amount, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\tip_lfoBAmount, msg[2]);
		});

		this.addCommand(\palm_p1, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\palm_p1, msg[2]);
		});
		this.addCommand(\palm_p2, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\palm_p2, msg[2]);
		});
		this.addCommand(\palm_p3, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\palm_p3, msg[2]);
		});
		this.addCommand(\palm_p4, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\palm_p4, msg[2]);
		});
		this.addCommand(\palm_p5, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\palm_p5, msg[2]);
		});
		this.addCommand(\palm_p6, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\palm_p6, msg[2]);
		});
		this.addCommand(\palm_p7, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\palm_p7, msg[2]);
		});
		this.addCommand(\palm_p8, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\palm_p8, msg[2]);
		});
		this.addCommand(\palm_lfo_a_freq, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\palm_lfoAFreq, msg[2]);
		});
		this.addCommand(\palm_lfo_a_amount, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\palm_lfoAAmount, msg[2]);
		});
		this.addCommand(\palm_lfo_b_freq, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\palm_lfoBFreq, msg[2]);
		});
		this.addCommand(\palm_lfo_b_amount, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\palm_lfoBAmount, msg[2]);
		});

		this.addCommand(\foot_p1, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\foot_p1, msg[2]);
		});
		this.addCommand(\foot_p2, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\foot_p2, msg[2]);
		});
		this.addCommand(\foot_p3, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\foot_p3, msg[2]);
		});
		this.addCommand(\foot_p4, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\foot_p4, msg[2]);
		});
		this.addCommand(\foot_p5, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\foot_p5, msg[2]);
		});
		this.addCommand(\foot_p6, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\foot_p6, msg[2]);
		});
		this.addCommand(\foot_p7, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\foot_p7, msg[2]);
		});
		this.addCommand(\foot_p8, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\foot_p8, msg[2]);
		});
		this.addCommand(\foot_lfo_a_freq, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\foot_lfoAFreq, msg[2]);
		});
		this.addCommand(\foot_lfo_a_amount, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\foot_lfoAAmount, msg[2]);
		});
		this.addCommand(\foot_lfo_b_freq, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\foot_lfoBFreq, msg[2]);
		});
		this.addCommand(\foot_lfo_b_amount, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\foot_lfoBAmount, msg[2]);
		});

		this.addCommand(\eg_pitch, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\eg_pitch, msg[2]);
		});
		this.addCommand(\eg_p1, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\eg_p1, msg[2]);
		});
		this.addCommand(\eg_p2, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\eg_p2, msg[2]);
		});
		this.addCommand(\eg_p3, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\eg_p3, msg[2]);
		});
		this.addCommand(\eg_p4, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\eg_p4, msg[2]);
		});
		this.addCommand(\eg_p5, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\eg_p5, msg[2]);
		});
		this.addCommand(\eg_p6, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\eg_p6, msg[2]);
		});
		this.addCommand(\eg_p7, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\eg_p7, msg[2]);
		});
		this.addCommand(\eg_p8, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\eg_p8, msg[2]);
		});
		this.addCommand(\eg_lfo_a_freq, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\eg_lfoAFreq, msg[2]);
		});
		this.addCommand(\eg_lfo_a_amount, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\eg_lfoAAmount, msg[2]);
		});
		this.addCommand(\eg_lfo_b_freq, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\eg_lfoBFreq, msg[2]);
		});
		this.addCommand(\eg_lfo_b_amount, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\eg_lfoBAmount, msg[2]);
		});

		this.addCommand(\lfo_a_pitch, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoA_pitch, msg[2]);
		});
		this.addCommand(\lfo_a_amp, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoA_amp, msg[2]);
		});
		this.addCommand(\lfo_a_p1, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoA_p1, msg[2]);
		});
		this.addCommand(\lfo_a_p2, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoA_p2, msg[2]);
		});
		this.addCommand(\lfo_a_p3, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoA_p3, msg[2]);
		});
		this.addCommand(\lfo_a_p4, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoA_p4, msg[2]);
		});
		this.addCommand(\lfo_a_p5, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoA_p5, msg[2]);
		});
		this.addCommand(\lfo_a_p6, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoA_p6, msg[2]);
		});
		this.addCommand(\lfo_a_p7, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoA_p7, msg[2]);
		});
		this.addCommand(\lfo_a_p8, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoA_p8, msg[2]);
		});
		this.addCommand(\lfo_a_lfo_b_freq, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoA_lfoBFreq, msg[2]);
		});
		this.addCommand(\lfo_a_lfo_b_amount, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoA_lfoBAmount, msg[2]);
		});

		this.addCommand(\lfo_b_pitch, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoB_pitch, msg[2]);
		});
		this.addCommand(\lfo_b_amp, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoB_amp, msg[2]);
		});
		this.addCommand(\lfo_b_p1, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoB_p1, msg[2]);
		});
		this.addCommand(\lfo_b_p2, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoB_p2, msg[2]);
		});
		this.addCommand(\lfo_b_p3, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoB_p3, msg[2]);
		});
		this.addCommand(\lfo_b_p4, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoB_p4, msg[2]);
		});
		this.addCommand(\lfo_b_p5, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoB_p5, msg[2]);
		});
		this.addCommand(\lfo_b_p6, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoB_p6, msg[2]);
		});
		this.addCommand(\lfo_b_p7, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoB_p7, msg[2]);
		});
		this.addCommand(\lfo_b_p8, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoB_p8, msg[2]);
		});
		this.addCommand(\lfo_b_lfo_a_freq, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoB_lfoAFreq, msg[2]);
		});
		this.addCommand(\lfo_b_lfo_a_amount, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\lfoB_lfoAAmount, msg[2]);
		});

		this.addCommand(\pitch_p1, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\pitch_p1, msg[2]);
		});
		this.addCommand(\pitch_p2, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\pitch_p2, msg[2]);
		});
		this.addCommand(\pitch_p3, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\pitch_p3, msg[2]);
		});
		this.addCommand(\pitch_p4, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\pitch_p4, msg[2]);
		});
		this.addCommand(\pitch_p5, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\pitch_p5, msg[2]);
		});
		this.addCommand(\pitch_p6, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\pitch_p6, msg[2]);
		});
		this.addCommand(\pitch_p7, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\pitch_p7, msg[2]);
		});
		this.addCommand(\pitch_p8, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\pitch_p8, msg[2]);
		});

		this.addCommand(\voice1_fm, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\voice1_fm, msg[2]);
		});
		this.addCommand(\voice2_fm, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\voice2_fm, msg[2]);
		});
		this.addCommand(\voice3_fm, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\voice3_fm, msg[2]);
		});
		this.addCommand(\voice4_fm, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\voice4_fm, msg[2]);
		});
		this.addCommand(\voice5_fm, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\voice5_fm, msg[2]);
		});
		this.addCommand(\voice6_fm, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\voice6_fm, msg[2]);
		});
		this.addCommand(\voice7_fm, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\voice7_fm, msg[2]);
		});

		this.addCommand(\octave, "ii", {
			arg msg;
			audioSynths[msg[1] - 1].set(\octave, msg[2]);
		});

		this.addCommand(\detune_type, "if", {
			arg msg;
			audioSynths[msg[1] - 1].set(\detuneType, msg[2]);
		});

		this.addCommand(\fade_size, "if", {
			arg msg;
			audioSynths[msg[1] - 1].set(\fadeSize, msg[2]);
		});

		this.addCommand(\fm_cutoff, "if", {
			arg msg;
			audioSynths[msg[1] - 1].set(\fmCutoff, msg[2]);
		});

		this.addCommand(\lp_cutoff, "if", {
			arg msg;
			audioSynths[msg[1] - 1].set(\lpCutoff, msg[2]);
		});
		this.addCommand(\hp_cutoff, "if", {
			arg msg;
			audioSynths[msg[1] - 1].set(\hpCutoff, msg[2]);
		});

		this.addCommand(\out_level, "if", {
			arg msg;
			audioSynths[msg[1] - 1].set(\outLevel, msg[2]);
		});

		this.addCommand(\reply_rate, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\replyRate, msg[2]);
		});
		this.addCommand(\eg_gate_trig, "ii", {
			arg msg;
			controlSynths[msg[1] - 1].set(\egGateTrig, msg[2]);
		});
		this.addCommand(\trig_length, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\trigLength, msg[2]);
		});
	}

	free {
		controlSynths.do({ |synth| synth.free });
		audioSynths.do({ |synth| synth.free });
		controlBuffers.do({ |buffer| buffer.free });
		replyFunc.free;
	}
}
