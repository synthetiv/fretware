Engine_Cule : CroneEngine {

	// TODO: replace or augment buses with buffers
	// var ampBus;
	// var freqBus;
	var pitchBus;
	var tipBus;
	var palmBus;
	var gateBus;
	var synth;
	var buffer;

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
				lfoAFreq = 0.9,
				lfoBFreq = 1.1,
				fb = 0,
				fold = 0.3,
				lag = 0.1,

				tip_amp = 1,
				tip_fb = 0,
				tip_fold = 0,
				// TODO: include EG times as mod destinations
				tip_egAmount = 0,
				tip_lfoAFreq = 0,
				tip_lfoAAmount = 0,
				tip_lfoBFreq = 0,
				tip_lfoBAmount = 0,

				palm_amp = 0,
				palm_fb = 0,
				palm_fold = -1,
				palm_egAmount = 0,
				palm_lfoAFreq = 0,
				palm_lfoAAmount = 0,
				palm_lfoBFreq = 0,
				palm_lfoBAmount = 0,

				eg_pitch = 0,
				eg_amp = 0,
				eg_fb = 0,
				eg_fold = 0,

				lfoA_pitch = 0,
				lfoA_amp = 0,
				lfoA_fb = 0,
				lfoA_fold = 0,

				lfoB_pitch = 0,
				lfoB_amp = 0,
				lfoB_fb = 0,
				lfoB_fold = 0,

				pitch_fb = -0.1,
				pitch_fold = -0.1;
				// TODO: pitch -> LFO freqs and amounts
				// TODO: EG -> LFO freqs and amounts, and vice versa

			var bufferPhase,
				pitch, tip, palm, gate,
				controllers,
				eg, lfoA, lfoB,
				modulators,
				hz, amp, sine, folded;

			bufferPhase = Phasor.kr(rate: 1 - freeze, end: BufFrames.kr(buffer));
			BufWr.kr(In.kr([pitchBus, tipBus, palmBus, gateBus]), buffer, bufferPhase);
			// TODO: make delay a modulation destination (requires LocalOut/LocalIn)
			// when freeze is engaged, delay must be at least 1 frame, or we'll be writing to + reading from the same point
			// TODO: you may want to clear the buffer or reset the delay when freeze is disengaged,
			// to prevent hearing one delay period's worth of old input... or maybe that's fun
			# pitch, tip, palm, gate = BufRd.kr(4, buffer, bufferPhase - (delay * ControlRate.ir).max(freeze), interpolation: 1);

			// TODO: why can't I use MovingAverage.kr here to get a linear slew?!
			// if I try that, SC seems to just hang forever, no error message
			pitch = Lag.kr(pitch, pitchSlew);

			// slew direct control
			tip  = Lag.kr(tip,  lag);
			palm = Lag.kr(palm, lag);
			fb   = Lag.kr(fb,   lag);
			fold = Lag.kr(fold, lag);

			controllers = [tip, palm];

			// TODO: use LocalOut/LocalIn to let these modulate one another
			eg = EnvGen.kr(
				Env.adsr(attack, decay, sustain, release),
				gate,
				1 + Mix(controllers * [tip_egAmount, palm_egAmount])
			);
			lfoA = SinOsc.kr(
				lfoAFreq * 2.pow(Mix(controllers * [tip_lfoAFreq, palm_lfoAFreq])),
				0,
				1 + Mix(controllers * [tip_lfoAAmount, palm_lfoAAmount])
			);
			lfoB = SinOsc.kr(
				lfoBFreq * 2.pow(Mix(controllers * [tip_lfoBFreq, palm_lfoBFreq])),
				0,
				1 + Mix(controllers * [tip_lfoBAmount, palm_lfoBAmount])
			);

			modulators = [tip, palm, eg, lfoA, lfoB];

			hz = 2.pow(pitch + octave + Mix([eg, lfoA, lfoB] * [eg_pitch, lfoA_pitch, lfoB_pitch])) * baseFreq;
			amp = Mix(modulators * [tip_amp, palm_amp, eg_amp, lfoA_amp, lfoB_amp]).max(0);

			fb = (fb + Mix(modulators * [tip_fb, palm_fb, eg_fb, lfoA_fb, lfoB_fb])).max(0);
			fold = (fold + Mix(modulators * [tip_fold, palm_fold, eg_fold, lfoA_fold, lfoB_fold])).max(0.1);

			sine = SinOscFB.ar(hz, fb);
			folded = SinOsc.ar(0, pi * fold * sine) * amp;

			Out.ar(context.out_b, folded ! 2);
		}).add;

		context.server.sync;

		// TODO: use array fill and stuff -- arrays of buffers and synths
		buffer = Buffer.alloc(context.server, context.server.sampleRate / context.server.options.blockSize * 8, 4);
		synth = Synth.new(\line, [
			\buffer, buffer,
			\in_l, context.in_b[0],
			\in_r, context.in_b[1]
		], context.og); // "output" group

		this.addCommand(\delay, "f", {
			arg msg;
			synth.set(\delay, msg[1]);
		});

		this.addCommand(\freeze, "i", {
			arg msg;
			synth.set(\freeze, msg[1]);
		});

		this.addCommand(\pitch, "f", {
			arg msg;
			pitchBus.setSynchronous(msg[1]);
		});

		this.addCommand(\gate, "i", {
			arg msg;
			gateBus.setSynchronous(msg[1]);
		});

		this.addCommand(\pitch_slew, "f", {
			arg msg;
			synth.set(\pitchSlew, msg[1]);
		});

		this.addCommand(\base_freq, "f", {
			arg msg;
			synth.set(\baseFreq, msg[1]);
		});

		this.addCommand(\tip, "f", {
			arg msg;
			tipBus.setSynchronous(msg[1]);
		});

		this.addCommand(\palm, "f", {
			arg msg;
			palmBus.setSynchronous(msg[1]);
		});

		this.addCommand(\lfo_a_freq, "f", {
			arg msg;
			synth.set(\lfoAFreq, msg[1]);
		});

		this.addCommand(\lfo_b_freq, "f", {
			arg msg;
			synth.set(\lfoBFreq, msg[1]);
		});

		this.addCommand(\fb, "f", {
			arg msg;
			synth.set(\fb, msg[1]);
		});

		this.addCommand(\fold, "f", {
			arg msg;
			synth.set(\fold, msg[1]);
		});

		this.addCommand(\octave, "i", {
			arg msg;
			synth.set(\octave, msg[1]);
		});

		this.addCommand(\lag, "f", {
			arg msg;
			synth.set(\lag, msg[1]);
		});

		this.addCommand(\tip_amp, "f", {
			arg msg;
			synth.set(\tip_amp, msg[1]);
		});
		this.addCommand(\tip_fb, "f", {
			arg msg;
			synth.set(\tip_fb, msg[1]);
		});
		this.addCommand(\tip_fold, "f", {
			arg msg;
			synth.set(\tip_fold, msg[1]);
		});
		this.addCommand(\tip_eg_amount, "f", {
			arg msg;
			synth.set(\tip_egAmount, msg[1]);
		});
		this.addCommand(\tip_lfo_a_freq, "f", {
			arg msg;
			synth.set(\tip_lfoAFreq, msg[1]);
		});
		this.addCommand(\tip_lfo_a_amount, "f", {
			arg msg;
			synth.set(\tip_lfoAAmount, msg[1]);
		});
		this.addCommand(\tip_lfo_b_freq, "f", {
			arg msg;
			synth.set(\tip_lfoBFreq, msg[1]);
		});
		this.addCommand(\tip_lfo_b_amount, "f", {
			arg msg;
			synth.set(\tip_lfoBAmount, msg[1]);
		});

		this.addCommand(\palm_amp, "f", {
			arg msg;
			synth.set(\palm_amp, msg[1]);
		});
		this.addCommand(\palm_fb, "f", {
			arg msg;
			synth.set(\palm_fb, msg[1]);
		});
		this.addCommand(\palm_fold, "f", {
			arg msg;
			synth.set(\palm_fold, msg[1]);
		});
		this.addCommand(\palm_eg_amount, "f", {
			arg msg;
			synth.set(\palm_egAmount, msg[1]);
		});
		this.addCommand(\palm_lfo_a_freq, "f", {
			arg msg;
			synth.set(\palm_lfoAFreq, msg[1]);
		});
		this.addCommand(\palm_lfo_a_amount, "f", {
			arg msg;
			synth.set(\palm_lfoAAmount, msg[1]);
		});
		this.addCommand(\palm_lfo_b_freq, "f", {
			arg msg;
			synth.set(\palm_lfoBFreq, msg[1]);
		});
		this.addCommand(\palm_lfo_b_amount, "f", {
			arg msg;
			synth.set(\palm_lfoBAmount, msg[1]);
		});

		this.addCommand(\eg_pitch, "f", {
			arg msg;
			synth.set(\eg_pitch, msg[1]);
		});
		this.addCommand(\eg_amp, "f", {
			arg msg;
			synth.set(\eg_amp, msg[1]);
		});
		this.addCommand(\eg_fb, "f", {
			arg msg;
			synth.set(\eg_fb, msg[1]);
		});
		this.addCommand(\eg_fold, "f", {
			arg msg;
			synth.set(\eg_fold, msg[1]);
		});

		this.addCommand(\lfo_a_pitch, "f", {
			arg msg;
			synth.set(\lfoA_pitch, msg[1]);
		});
		this.addCommand(\lfo_a_amp, "f", {
			arg msg;
			synth.set(\lfoA_amp, msg[1]);
		});
		this.addCommand(\lfo_a_fb, "f", {
			arg msg;
			synth.set(\lfoA_fb, msg[1]);
		});
		this.addCommand(\lfo_a_fold, "f", {
			arg msg;
			synth.set(\lfoA_fold, msg[1]);
		});

		this.addCommand(\lfo_b_pitch, "f", {
			arg msg;
			synth.set(\lfoB_pitch, msg[1]);
		});
		this.addCommand(\lfo_b_amp, "f", {
			arg msg;
			synth.set(\lfoB_amp, msg[1]);
		});
		this.addCommand(\lfo_b_fb, "f", {
			arg msg;
			synth.set(\lfoB_fb, msg[1]);
		});
		this.addCommand(\lfo_b_fold, "f", {
			arg msg;
			synth.set(\lfoB_fold, msg[1]);
		});

		this.addCommand(\pitch_fb, "f", {
			arg msg;
			synth.set(\pitch_fb, msg[1]);
		});
		this.addCommand(\pitch_fold, "f", {
			arg msg;
			synth.set(\pitch_fold, msg[1]);
		});
	}

	free {
		synth.free;
		// ampBus.free;
		// freqBus.free;
	}
}
