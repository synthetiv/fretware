Engine_Cule : CroneEngine {

	classvar n_voices = 3;

	// TODO: replace or augment buses with buffers
	// var ampBus;
	// var freqBus;
	var pitchBus;
	var tipBus;
	var palmBus;
	var gateBus;
	var buffers;
	var synths;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {

		pitchBus = Bus.control(context.server);
		tipBus = Bus.control(context.server);
		palmBus = Bus.control(context.server);
		gateBus = Bus.control(context.server);

		SynthDef.new(\line, {

			arg buffer,
				delay = 0,
				freeze = 0,

				baseFreq = 60.midicps,
				pitchSlew = 0.01,
				octave = 0,
				attack = 0.01,
				decay = 0.1,
				sustain = 0.8,
				release = 0.3,
				egAmount = 1,
				lfoAType = 0,
				lfoAFreq = 0.9,
				lfoAAmount = 1,
				lfoBType = 0,
				lfoBFreq = 1.1,
				lfoBAmount = 1,
				fb = 0,
				fold = 0.3,
				lag = 0.1,

				tip_amp = 1,
				tip_delay = 0,
				tip_fb = 0,
				tip_fold = 0,
				// TODO: include EG times as mod destinations
				tip_egAmount = 0,
				tip_lfoAFreq = 0,
				tip_lfoAAmount = 0,
				tip_lfoBFreq = 0,
				tip_lfoBAmount = 0,

				palm_amp = 0,
				palm_delay = 0,
				palm_fb = 0,
				palm_fold = -1,
				palm_egAmount = 0,
				palm_lfoAFreq = 0,
				palm_lfoAAmount = 0,
				palm_lfoBFreq = 0,
				palm_lfoBAmount = 0,

				eg_pitch = 0,
				eg_amp = 0,
				eg_delay = 0,
				eg_fb = 0,
				eg_fold = 0,
				eg_lfoAFreq = 0,
				eg_lfoAAmount = 0,
				eg_lfoBFreq = 0,
				eg_lfoBAmount = 0,

				lfoA_pitch = 0,
				lfoA_amp = 0,
				lfoA_delay = 0,
				lfoA_fb = 0,
				lfoA_fold = 0,
				lfoA_egAmount = 0,
				lfoA_lfoBFreq = 0,
				lfoA_lfoBAmount = 0,

				lfoB_pitch = 0,
				lfoB_amp = 0,
				lfoB_delay = 0,
				lfoB_fb = 0,
				lfoB_fold = 0,
				lfoB_egAmount = 0,
				lfoB_lfoAFreq = 0,
				lfoB_lfoAAmount = 0,

				pitch_fb = -0.1,
				pitch_fold = -0.1;
				// TODO: pitch -> LFO freqs and amounts
				// TODO: EG -> LFO freqs and amounts, and vice versa

			var bufferPhase,
				delayedControls,
				pitch, tip, palm, gate,
				eg, lfoA, lfoB,
				hz, amp, sine, folded;

			var modulators = LocalIn.kr(5);

			bufferPhase = Phasor.kr(end: BufFrames.kr(buffer));
			delayedControls = BufRd.kr(4, buffer, bufferPhase - (delay * ControlRate.ir), interpolation: 1);
			# pitch, tip, palm, gate = delayedControls;
			// if freeze is active, feed the delay buffer with the delayed signal.
			// otherwise, feed it the actual control input values.
			BufWr.kr(
				Select.kr(freeze, [
					In.kr([pitchBus, tipBus, palmBus, gateBus]),
					delayedControls
				]),
				buffer,
				bufferPhase
			);
			delay = delay * 2.pow(Mix(modulators * [tip_delay, palm_delay, eg_delay, lfoA_delay, lfoB_delay]));
			delay = delay.clip(0, 8);
			// TODO: you may want to clear the buffer or reset the delay when freeze is disengaged,
			// to prevent hearing one delay period's worth of old input... or maybe that's fun

			// TODO: why can't I use MovingAverage.kr here to get a linear slew?!
			// if I try that, SC seems to just hang forever, no error message
			pitch = Lag.kr(pitch, pitchSlew);

			// slew direct control
			tip  = Lag.kr(tip,  lag);
			palm = Lag.kr(palm, lag);
			fb   = Lag.kr(fb,   lag);
			fold = Lag.kr(fold, lag);

			eg = EnvGen.kr(
				Env.adsr(attack, decay, sustain, release),
				gate,
				// TODO: "amounts" are a poor replacement for multiplication within
				// a given modulation routing, e.g. (env * (0.5 + tip)) -> osc_fb.
				// that ^ could be described as multiplying at the input, while
				// amounts multiply at the output (EG will be scaled like this no
				// matter where it's used).
				egAmount + Mix(modulators * [tip_egAmount, palm_egAmount, 0, lfoA_egAmount, lfoB_egAmount])
			);

			lfoAFreq = lfoAFreq * 2.pow(Mix(modulators * [tip_lfoAFreq, palm_lfoAFreq, eg_lfoAFreq, 0, lfoB_lfoAFreq]));
			lfoAAmount = lfoAAmount + Mix(modulators * [tip_lfoAAmount, palm_lfoAAmount, eg_lfoAAmount, 0, lfoB_lfoAAmount]);
			lfoA = lfoAAmount * Select.kr(lfoAType, [
				SinOsc.kr(lfoAFreq),
				LFTri.kr(lfoAFreq),
				LFSaw.kr(lfoAFreq),
				LFNoise1.kr(lfoAFreq),
				LFNoise0.kr(lfoAFreq)
			]);

			lfoBFreq = lfoBFreq * 2.pow(Mix(modulators * [tip_lfoBFreq, palm_lfoBFreq, eg_lfoBFreq, lfoA_lfoBFreq, 0]));
			lfoBAmount = lfoBAmount + Mix(modulators * [tip_lfoBAmount, palm_lfoBAmount, eg_lfoBAmount, lfoA_lfoBAmount, 0]);
			lfoB = lfoBAmount * Select.kr(lfoBType, [
				SinOsc.kr(lfoBFreq),
				LFTri.kr(lfoBFreq),
				LFSaw.kr(lfoBFreq),
				LFNoise1.kr(lfoBFreq),
				LFNoise0.kr(lfoBFreq)
			]);

			LocalOut.kr([tip, palm, eg, lfoA, lfoB]);

			hz = 2.pow(pitch + octave + Mix([eg, lfoA, lfoB] * [eg_pitch, lfoA_pitch, lfoB_pitch])) * baseFreq;
			amp = Mix(modulators * [tip_amp, palm_amp, eg_amp, lfoA_amp, lfoB_amp]).max(0);

			fb = (fb + Mix(modulators * [tip_fb, palm_fb, eg_fb, lfoA_fb, lfoB_fb])).max(0);
			fold = (fold + Mix(modulators * [tip_fold, palm_fold, eg_fold, lfoA_fold, lfoB_fold])).max(0.1);

			sine = SinOscFB.ar(hz, fb);
			folded = SinOsc.ar(0, pi * fold * sine) * amp;

			Out.ar(context.out_b, folded ! 2);
		}).add;

		context.server.sync;

		buffers = Array.fill(n_voices, {
			Buffer.alloc(context.server, context.server.sampleRate / context.server.options.blockSize * 8, 4);
		});
		synths = Array.fill(n_voices, {
			arg i;
			Synth.new(\line, [
				\buffer, buffers[i],
				\delay, i * 0.2
			], context.og); // "output" group
		});

		this.addCommand(\delay, "if", {
			arg msg;
			synths[msg[1] - 1].set(\delay, msg[2]);
		});

		this.addCommand(\freeze, "ii", {
			arg msg;
			synths[msg[1] - 1].set(\freeze, msg[2]);
		});

		this.addCommand(\pitch, "f", {
			arg msg;
			pitchBus.setSynchronous(msg[1]);
		});

		this.addCommand(\gate, "i", {
			arg msg;
			gateBus.setSynchronous(msg[1]);
		});

		this.addCommand(\pitch_slew, "if", {
			arg msg;
			synths[msg[1] - 1].set(\pitchSlew, msg[2]);
		});

		this.addCommand(\base_freq, "if", {
			arg msg;
			synths[msg[1] - 1].set(\baseFreq, msg[2]);
		});

		this.addCommand(\tip, "f", {
			arg msg;
			tipBus.setSynchronous(msg[1]);
		});

		this.addCommand(\palm, "f", {
			arg msg;
			palmBus.setSynchronous(msg[1]);
		});

		this.addCommand(\lfo_a_type, "ii", {
			arg msg;
			synths[msg[1] - 1].set(\lfoAType, msg[2] - 1);
		});
		this.addCommand(\lfo_a_freq, "if", {
			arg msg;
			synths[msg[1] - 1].set(\lfoAFreq, msg[2]);
		});
		this.addCommand(\lfo_a_amount, "if", {
			arg msg;
			synths[msg[1] - 1].set(\lfoAAmount, msg[2]);
		});

		this.addCommand(\lfo_b_type, "ii", {
			arg msg;
			synths[msg[1] - 1].set(\lfoBType, msg[2] - 1);
		});
		this.addCommand(\lfo_b_freq, "if", {
			arg msg;
			synths[msg[1] - 1].set(\lfoBFreq, msg[2]);
		});
		this.addCommand(\lfo_b_amount, "if", {
			arg msg;
			synths[msg[1] - 1].set(\lfoBAmount, msg[2]);
		});

		this.addCommand(\attack, "if", {
			arg msg;
			synths[msg[1] - 1].set(\attack, msg[2]);
		});

		this.addCommand(\decay, "if", {
			arg msg;
			synths[msg[1] - 1].set(\decay, msg[2]);
		});

		this.addCommand(\sustain, "if", {
			arg msg;
			synths[msg[1] - 1].set(\sustain, msg[2]);
		});

		this.addCommand(\release, "if", {
			arg msg;
			synths[msg[1] - 1].set(\release, msg[2]);
		});

		this.addCommand(\eg_amount, "if", {
			arg msg;
			synths[msg[1] - 1].set(\egAmount, msg[2]);
		});

		this.addCommand(\fb, "if", {
			arg msg;
			synths[msg[1] - 1].set(\fb, msg[2]);
		});

		this.addCommand(\fold, "if", {
			arg msg;
			synths[msg[1] - 1].set(\fold, msg[2]);
		});

		this.addCommand(\octave, "ii", {
			arg msg;
			synths[msg[1] - 1].set(\octave, msg[2]);
		});

		this.addCommand(\lag, "if", {
			arg msg;
			synths[msg[1] - 1].set(\lag, msg[2]);
		});

		this.addCommand(\tip_amp, "if", {
			arg msg;
			synths[msg[1] - 1].set(\tip_amp, msg[2]);
		});
		this.addCommand(\tip_delay, "if", {
			arg msg;
			synths[msg[1] - 1].set(\tip_delay, msg[2]);
		});
		this.addCommand(\tip_fb, "if", {
			arg msg;
			synths[msg[1] - 1].set(\tip_fb, msg[2]);
		});
		this.addCommand(\tip_fold, "if", {
			arg msg;
			synths[msg[1] - 1].set(\tip_fold, msg[2]);
		});
		this.addCommand(\tip_eg_amount, "if", {
			arg msg;
			synths[msg[1] - 1].set(\tip_egAmount, msg[2]);
		});
		this.addCommand(\tip_lfo_a_freq, "if", {
			arg msg;
			synths[msg[1] - 1].set(\tip_lfoAFreq, msg[2]);
		});
		this.addCommand(\tip_lfo_a_amount, "if", {
			arg msg;
			synths[msg[1] - 1].set(\tip_lfoAAmount, msg[2]);
		});
		this.addCommand(\tip_lfo_b_freq, "if", {
			arg msg;
			synths[msg[1] - 1].set(\tip_lfoBFreq, msg[2]);
		});
		this.addCommand(\tip_lfo_b_amount, "if", {
			arg msg;
			synths[msg[1] - 1].set(\tip_lfoBAmount, msg[2]);
		});

		this.addCommand(\palm_amp, "if", {
			arg msg;
			synths[msg[1] - 1].set(\palm_amp, msg[2]);
		});
		this.addCommand(\palm_delay, "if", {
			arg msg;
			synths[msg[1] - 1].set(\palm_delay, msg[2]);
		});
		this.addCommand(\palm_fb, "if", {
			arg msg;
			synths[msg[1] - 1].set(\palm_fb, msg[2]);
		});
		this.addCommand(\palm_fold, "if", {
			arg msg;
			synths[msg[1] - 1].set(\palm_fold, msg[2]);
		});
		this.addCommand(\palm_eg_amount, "if", {
			arg msg;
			synths[msg[1] - 1].set(\palm_egAmount, msg[2]);
		});
		this.addCommand(\palm_lfo_a_freq, "if", {
			arg msg;
			synths[msg[1] - 1].set(\palm_lfoAFreq, msg[2]);
		});
		this.addCommand(\palm_lfo_a_amount, "if", {
			arg msg;
			synths[msg[1] - 1].set(\palm_lfoAAmount, msg[2]);
		});
		this.addCommand(\palm_lfo_b_freq, "if", {
			arg msg;
			synths[msg[1] - 1].set(\palm_lfoBFreq, msg[2]);
		});
		this.addCommand(\palm_lfo_b_amount, "if", {
			arg msg;
			synths[msg[1] - 1].set(\palm_lfoBAmount, msg[2]);
		});

		this.addCommand(\eg_pitch, "if", {
			arg msg;
			synths[msg[1] - 1].set(\eg_pitch, msg[2]);
		});
		this.addCommand(\eg_amp, "if", {
			arg msg;
			synths[msg[1] - 1].set(\eg_amp, msg[2]);
		});
		this.addCommand(\eg_delay, "if", {
			arg msg;
			synths[msg[1] - 1].set(\eg_delay, msg[2]);
		});
		this.addCommand(\eg_fb, "if", {
			arg msg;
			synths[msg[1] - 1].set(\eg_fb, msg[2]);
		});
		this.addCommand(\eg_fold, "if", {
			arg msg;
			synths[msg[1] - 1].set(\eg_fold, msg[2]);
		});
		this.addCommand(\eg_lfo_a_freq, "if", {
			arg msg;
			synths[msg[1] - 1].set(\eg_lfoAFreq, msg[2]);
		});
		this.addCommand(\eg_lfo_a_amount, "if", {
			arg msg;
			synths[msg[1] - 1].set(\eg_lfoAAmount, msg[2]);
		});
		this.addCommand(\eg_lfo_b_freq, "if", {
			arg msg;
			synths[msg[1] - 1].set(\eg_lfoBFreq, msg[2]);
		});
		this.addCommand(\eg_lfo_b_amount, "if", {
			arg msg;
			synths[msg[1] - 1].set(\eg_lfoBAmount, msg[2]);
		});

		this.addCommand(\lfo_a_pitch, "if", {
			arg msg;
			synths[msg[1] - 1].set(\lfoA_pitch, msg[2]);
		});
		this.addCommand(\lfo_a_amp, "if", {
			arg msg;
			synths[msg[1] - 1].set(\lfoA_amp, msg[2]);
		});
		this.addCommand(\lfo_a_delay, "if", {
			arg msg;
			synths[msg[1] - 1].set(\lfoA_delay, msg[2]);
		});
		this.addCommand(\lfo_a_fb, "if", {
			arg msg;
			synths[msg[1] - 1].set(\lfoA_fb, msg[2]);
		});
		this.addCommand(\lfo_a_fold, "if", {
			arg msg;
			synths[msg[1] - 1].set(\lfoA_fold, msg[2]);
		});
		this.addCommand(\lfo_a_eg_amount, "if", {
			arg msg;
			synths[msg[1] - 1].set(\lfoA_egAmount, msg[2]);
		});
		this.addCommand(\lfo_a_lfo_b_freq, "if", {
			arg msg;
			synths[msg[1] - 1].set(\lfoA_lfoBFreq, msg[2]);
		});
		this.addCommand(\lfo_a_lfo_b_amount, "if", {
			arg msg;
			synths[msg[1] - 1].set(\lfoA_lfoBAmount, msg[2]);
		});

		this.addCommand(\lfo_b_pitch, "if", {
			arg msg;
			synths[msg[1] - 1].set(\lfoB_pitch, msg[2]);
		});
		this.addCommand(\lfo_b_amp, "if", {
			arg msg;
			synths[msg[1] - 1].set(\lfoB_amp, msg[2]);
		});
		this.addCommand(\lfo_b_delay, "if", {
			arg msg;
			synths[msg[1] - 1].set(\lfoB_delay, msg[2]);
		});
		this.addCommand(\lfo_b_fb, "if", {
			arg msg;
			synths[msg[1] - 1].set(\lfoB_fb, msg[2]);
		});
		this.addCommand(\lfo_b_fold, "if", {
			arg msg;
			synths[msg[1] - 1].set(\lfoB_fold, msg[2]);
		});
		this.addCommand(\lfo_b_eg_amount, "if", {
			arg msg;
			synths[msg[1] - 1].set(\lfoB_egAmount, msg[2]);
		});
		this.addCommand(\lfo_b_lfo_a_freq, "if", {
			arg msg;
			synths[msg[1] - 1].set(\lfoB_lfoAFreq, msg[2]);
		});
		this.addCommand(\lfo_b_lfo_a_amount, "if", {
			arg msg;
			synths[msg[1] - 1].set(\lfoB_lfoAAmount, msg[2]);
		});

		this.addCommand(\pitch_fb, "if", {
			arg msg;
			synths[msg[1] - 1].set(\pitch_fb, msg[2]);
		});
		this.addCommand(\pitch_fold, "if", {
			arg msg;
			synths[msg[1] - 1].set(\pitch_fold, msg[2]);
		});
	}

	free {
		synths.do({ |synth| synth.free });
		buffers.do({ |buffer| buffer.free });
		pitchBus.free;
		tipBus.free;
		palmBus.free;
		gateBus.free;
	}
}
