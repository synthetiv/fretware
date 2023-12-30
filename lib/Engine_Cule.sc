Engine_Cule : CroneEngine {

	classvar nVoices = 7;
	classvar maxLoopTime = 16;

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

	alloc {

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
			Bus.control(context.server, 6);
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
				ampMode = 0, // 0 = tip only; 1 = tip * AR; 2 = ADSR
				delay = 0,
				freeze = 0,
				loopLength = 0.3,
				loopPosition = 0,

				detune = 0,
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
				lag = 0.1,

				tip_p1 = 0,
				tip_p2 = 0,
				tip_p3 = 0,
				tip_p4 = 0,
				// TODO: include EG times as mod destinations
				tip_lfoAFreq = 0,
				tip_lfoAAmount = 0,
				tip_lfoBFreq = 0,
				tip_lfoBAmount = 0,

				palm_p1 = 0,
				palm_p2 = 0,
				palm_p3 = 0,
				palm_p4 = 0,
				palm_lfoAFreq = 0,
				palm_lfoAAmount = 0,
				palm_lfoBFreq = 0,
				palm_lfoBAmount = 0,

				eg_pitch = 0,
				eg_p1 = 0,
				eg_p2 = 0,
				eg_p3 = 0,
				eg_p4 = 0,
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
				lfoA_lfoBFreq = 0,
				lfoA_lfoBAmount = 0,

				lfoB_pitch = 0,
				lfoB_amp = 0,
				lfoB_p1 = 0,
				lfoB_p2 = 0,
				lfoB_p3 = 0,
				lfoB_p4 = 0,
				lfoB_lfoAFreq = 0,
				lfoB_lfoAAmount = 0,

				pitch_p1 = -0.1,
				pitch_p2 = -0.1,
				pitch_p3 = 0,
				pitch_p4 = 0,
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

			var modulators = LocalIn.kr(6);

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
				modulators[3]
			]) * (1 + Mix(modulators[4..5] * [lfoA_amp, lfoB_amp]))).max(0);

			var bufferRateScale = 0.5,
				bufferRate = ControlRate.ir * bufferRateScale;

			bufferLength = BufFrames.kr(buffer);
			bufferPhase = Phasor.kr(rate: bufferRateScale * (1 - freeze), end: bufferLength);
			// delay must be at least 1 frame, or we'll be writing to + reading from the same point
			delayPhase = bufferPhase - (delay * bufferRate).max(1);
			loopStart = bufferPhase - (loopLength * bufferRate).min(bufferLength);
			loopPhase = Phasor.kr(freeze, bufferRateScale, loopStart, bufferPhase, loopStart);
			// TODO: confirm that this is really firing when it's supposed to (i.e. when loopPhase
			// resets)! if not, either fix it, or do away with it
			loopTrigger = Trig.kr(BinaryOpUGen.new('==', loopPhase, loopStart));
			loopOffset = Latch.kr(bufferLength - (loopLength * bufferRate), loopTrigger) * loopPosition;
			loopPhase = loopPhase - loopOffset;
			BufWr.kr([pitch, tip, palm, amp], buffer, bufferPhase);
			# pitch, tip, palm, amp = BufRd.kr(4, buffer, Select.kr(freeze, [delayPhase, loopPhase]), interpolation: 1);

			// slew direct control
			tip  = Lag.kr(tip,  lag);
			palm = Lag.kr(palm, lag);
			p1   = Lag.kr(p1,   lag);
			p2   = Lag.kr(p2,   lag);
			p3   = Lag.kr(p3,   lag);
			p4   = Lag.kr(p4,   lag);

			eg = EnvGen.kr(
				Env.adsr(attack, decay, sustain, release),
				gateOrTrig,
				-6.dbamp
			);

			// TODO: if you cool it with some of these LFOs, can you bring back SinOscFB?
			lfoAFreq = lfoAFreq * 2.pow(Mix(modulators * [0, tip_lfoAFreq, palm_lfoAFreq, eg_lfoAFreq, 0, lfoB_lfoAFreq]));
			lfoAAmount = lfoAAmount + Mix(modulators * [0, tip_lfoAAmount, palm_lfoAAmount, eg_lfoAAmount, 0, lfoB_lfoAAmount]);
			lfoA = lfoAAmount * Select.kr(lfoAType, [
				SinOsc.kr(lfoAFreq),
				LFTri.kr(lfoAFreq),
				LFSaw.kr(lfoAFreq),
				LFNoise1.kr(lfoAFreq),
				LFNoise0.kr(lfoAFreq)
			]);

			lfoBFreq = lfoBFreq * 2.pow(Mix(modulators * [0, tip_lfoBFreq, palm_lfoBFreq, eg_lfoBFreq, lfoA_lfoBFreq, 0]));
			lfoBAmount = lfoBAmount + Mix(modulators * [0, tip_lfoBAmount, palm_lfoBAmount, eg_lfoBAmount, lfoA_lfoBAmount, 0]);
			lfoB = lfoBAmount * Select.kr(lfoBType, [
				SinOsc.kr(lfoBFreq),
				LFTri.kr(lfoBFreq),
				LFSaw.kr(lfoBFreq),
				LFNoise1.kr(lfoBFreq),
				LFNoise0.kr(lfoBFreq)
			]);

			LocalOut.kr([pitch, tip, palm, eg, lfoA, lfoB]);

			pitch = pitch + detune + Mix([eg, lfoA, lfoB] * [eg_pitch, lfoA_pitch, lfoB_pitch]);

			// send control values to polls, both regularly (replyRate Hz) and immediately when gate goes high or when voice loops
			SendReply.kr(trig: Impulse.kr(replyRate) + Changed.kr(pitch, 0.04), cmdName: '/voicePitchAmp', values: [voiceIndex, pitch, amp]);

			// TODO: why can't I use MovingAverage.kr here to get a linear slew?!
			// if I try that, SC seems to just hang forever, no error message
			pitch = Lag.kr(pitch, pitchSlew);

			// TODO: clip these values in the audio synth, not here
			p1 = (p1 + Mix(modulators * [pitch_p1, tip_p1, palm_p1, eg_p1, lfoA_p1, lfoB_p1]));
			p2 = (p2 + Mix(modulators * [pitch_p2, tip_p2, palm_p2, eg_p2, lfoA_p2, lfoB_p2]));
			p3 = (p3 + Mix(modulators * [pitch_p3, tip_p3, palm_p3, eg_p3, lfoA_p3, lfoB_p3]));
			p4 = (p4 + Mix(modulators * [pitch_p4, tip_p4, palm_p4, eg_p4, lfoA_p4, lfoB_p4]));

			// write FM mix to FM bus
			Out.ar(fmBus, Mix(InFeedback.ar(synthOutBuses) * [voice1_fm, voice2_fm, voice3_fm, voice4_fm, voice5_fm, voice6_fm, voice7_fm]));

			// write control signals to control bus
			Out.kr(controlBus, [pitch, amp, p1, p2, p3, p4]);
		}).add;

		// TODO: alt synths:
		// - square with pwm, cutoff, reso
		// - double (var?)saw with detune, cutoff, reso?
		// - wavetables... samples...
		// TODO: come up with a good way to make param labels descriptive, because who wants 'timbre A' and 'timbre B'

		SynthDef.new(\sine, {
			arg fmBus, controlBus, outBus, octave = 0, fmCutoff = 12000, lpCutoff = 23000, hpCutoff = 16, outLevel = 0.2;
			var pitch, amp, fmIndex, fmRatio, fold, foldBias,
				hz, modulator, fmMix, carrier, sine, ratios;
			# pitch, amp, fmIndex, fmRatio, fold, foldBias = In.kr(controlBus, 6);
			// ratios = Array.fill(8, { |n| (n + 1) / (1..4) }).flatten.asSet.asArray.sort;
			ratios = [ 1, 2, 3, 6, 8 ].collect({ |n| n / (1..4) }).flatten.asSet.asArray.sort;
			hz = 2.pow(pitch + octave) * In.kr(baseFreqBus);
			modulator = SinOsc.ar(hz * LinSelectX.kr((fmRatio.linlin(-1, 1, 0, 1) /* .lincurve(-1, 1, 0, 1, 1) */ * ratios.size).softRound(1, 0, 0.93), ratios));
			fmMix = In.ar(fmBus) + (modulator * fmIndex.linexp(0, 1, 0.01, 10pi));
			carrier = SinOsc.ar(hz, LPF.ar(fmMix, fmCutoff).mod(2pi));
			sine = LinXFade2.ar(modulator, carrier, fmIndex.linlin(-1, 0, -1, 1));
			sine = SinOsc.ar(0, (fold.linexp(-1, 1, 0.1, 10pi) * sine + foldBias.linlin(-1, 1, -pi / 2, pi / 2)));
			// compensate for DC offset introduced by fold bias
			sine = LeakDC.ar(sine);
			// compensate for lost amplitude due to bias (a fully rectified wave is half the amplitude of the original)
			sine = sine * (foldBias.abs + 1);
			// scale by amplitude control value
			sine = sine * amp;

			// write to bus for FM
			Out.ar(outBus, sine);

			// filter and write to main outs
			sine = LPF.ar(HPF.ar(sine, hpCutoff), lpCutoff);
			Out.ar(context.out_b, sine ! 2 * Lag.kr(outLevel, 0.05));
		}).add;

		SynthDef.new(\pulse, {
			arg fmBus, controlBus, outBus, outLevel = 0.2;
			// TODO: fit the 4 voice params to a standard range (-1 to 1? 0 to 10?) and then scale that range to something appropriate here
			var pitch, amp, pulsewidth, cutoff, pitchCutoff, resonance,
				hz, saw, delayed, pulse, cutoffHz, filtered; // TODO: actually... shouldn't pitch->cutoff routing be handled in the control synth? hmm
			// TODO: why does high-frequency FM seem not to do anything? is that just a feature of pulse->pulse FM (quite possible) or is PulseDPW like SinOscFB w/r/t audio-rate frequency updates?
			// TODO: try other filters
			# pitch, amp, pulsewidth, resonance, cutoff, pitchCutoff = In.kr(controlBus, 6);
			hz = 2.pow(pitch) * In.kr(baseFreqBus);
			saw = SawDPW.ar(hz);
			delayed = DelayC.ar(saw, 0.2, hz.reciprocal * pulsewidth.linlin(-1, 1, 0, 1));
			pulse = delayed - saw;
			// TODO: bummer, I think BMoog's frequency is updated at control rate, not audio rate. it also seems to be prone to blowing up under heavy modulation, even when clamped to nyquist.
			// RLPF seems to have the same issue. maybe all filters do...
			cutoffHz = (2.pow(pitch * ((pitchCutoff + 1) * 2) + cutoff.linexp(-1, 1, 0.01, 11) - 1) * In.kr(baseFreqBus) * (1 + In.ar(fmBus)));
			cutoffHz = cutoffHz.clip(10, SampleRate.ir / 2);
			// filtered = BMoog.ar(pulse, cutoffHz, resonance) * amp;
			filtered = RLPF.ar(pulse, cutoffHz, resonance.linexp(-1, 1, 1, 0.1)) * amp; // TODO: this still gets glitchy sometimes
			Out.ar(outBus, pulse * amp);
			Out.ar(context.out_b, filtered ! 2 * Lag.kr(outLevel, 0.05));
		}).add;

		// TODO: master bus FX like saturation, decimation...?

		context.server.sync;

		baseFreqBus.setSynchronous(60.midicps);

		controlBuffers = Array.fill(nVoices, {
			Buffer.alloc(context.server, context.server.sampleRate / context.server.options.blockSize * maxLoopTime, 4);
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
				\freeze, 1
			);
		});

		this.addCommand(\clear_loop, "i", {
			arg msg;
			controlSynths[msg[1] - 1].set(\freeze, 0);
		});

		this.addCommand(\loop_position, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\loopPosition, msg[2]);
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

		this.addCommand(\detune, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\detune, msg[2]);
		});

		this.addCommand(\tip, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\tip, msg[2]);
		});

		this.addCommand(\palm, "if", {
			arg msg;
			controlSynths[msg[1] - 1].set(\palm, msg[2]);
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
